-- The sync engine (docs/design.md §5.3, §5.4, §5.6): live PUTs, HELLO and
-- bucketed anti-entropy, members and the board name. Pure Lua 5.1. It reads
-- and writes boards only through the store, sends only through the outbox,
-- and gets everything else from `env`:
--
--   env.time()           monotonic seconds (GetTime())
--   env.after(s, fn)     runs fn after s seconds; returns a handle with :Cancel()
--   env.random()         a number in [0, 1)
--   env.class            the player's class token ("MAGE"), for roster colours
--   env.level            the player's level, for the roster's Level column
--   env.changed(boardId) optional: called when a board's sync state changes
--   env.synced(boardId)  optional: called when a board matches a peer's copy
--
-- The store's env supplies the player's name (env.me) and server time.
--
-- Every message goes to the board's own transport (its hidden channel, or
-- GUILD for a guild board): dest = { board = id }. Replies that are meant for
-- one member carry `to`, and ride the same broadcast so the other members
-- can see them. That's what lets responder suppression (§5.4) work.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Merge = ns.Merge or require("Core.Merge")
local Digest = ns.Digest or require("Core.Digest")
local Store = ns.Store or require("Core.Store")

local format = string.format
local floor = math.floor
local concat, sort = table.concat, table.sort

local Sync = {}
Sync.__index = Sync

Sync.PRESENCE = 13 * 60 -- seconds since a member was heard for them to count as online
Sync.HELLO_EVERY = 300 -- periodic HELLO, ± HELLO_JITTER
Sync.HELLO_JITTER = 60
Sync.HELLO_QUIET = 120 -- skip a periodic HELLO if one for the board was seen this recently
-- Responder delay (§5.4): members answer in rank order, one RESPONDER_STEP apart.
Sync.RESPONDER_BASE = 0.3
Sync.RESPONDER_STEP = 1.0
Sync.RESPONDER_JITTER = 0.4
Sync.RESPONDER_RANKS = 4
Sync.MEMBERS_DELAY = 0.5 -- to MEMBERS_DELAY + MEMBERS_SPREAD seconds
Sync.MEMBERS_SPREAD = 2.5
-- The bulk rule (§5.6).
Sync.BULK_BYTES = 8192
Sync.NOTE_BYTES = 150 -- rough wire cost of one note in a catch-up, IDX entry included
Sync.PARTIAL = 20 -- notes pulled in-game when the rest comes from the cloud
Sync.CLOUD_FRESH = 7 * 86400 -- the companion counts as running if it synced this recently
-- Envelope sizes.
Sync.IDX_ENTRIES = 60
Sync.PUT_BYTES = 600
Sync.NEED_IDS = 100
Sync.MEMBERS_PER = 100
Sync.MAX_LIST = 400 -- longest list accepted in any received envelope
Sync.SYNCING = 60 -- seconds a catch-up counts as in progress
Sync.LOG = 200

function Sync.new(store, outbox, env)
	local self = setmetatable({
		store = store,
		outbox = outbox,
		env = env,
		peers = {}, -- boardId -> name -> peer
		responders = {}, -- boardId .. "\0" .. requester -> timer
		membersTimers = {}, -- boardId -> timer
		metaTimers = {}, -- boardId -> timer
		helloTimers = {}, -- boardId -> timer
		lastHello = {}, -- boardId -> time a HELLO for it was last sent or seen
		skipped = {}, -- boardId -> the last periodic HELLO was skipped
		cache = {}, -- boardId -> digest summary
		syncing = {}, -- boardId -> { from, want = set, left, at }
		behind = {}, -- boardId -> { count, at }
		log = {},
		stats = { received = 0, ignored = 0, malformed = 0, merged = 0 },
	}, Sync)
	store:listen(function(change)
		self:onChange(change)
	end)
	return self
end

function Sync:me()
	return self.store.env.me
end

function Sync:time()
	return self.env.time()
end

function Sync:board(id)
	return self.store:all()[id]
end

function Sync:changed(boardId)
	if self.env.changed then
		self.env.changed(boardId)
	end
end

-- The debug log (§11): the newest Sync.LOG lines.
function Sync:note(fmt, ...)
	local log = self.log
	log[#log + 1] = { t = self.store.env.now(), line = select("#", ...) > 0 and format(fmt, ...) or fmt }
	if #log > Sync.LOG then
		table.remove(log, 1)
	end
end

-- Digests -----------------------------------------------------------------------------

local function emptySummary()
	local buckets, counts, bytes = {}, {}, {}
	for i = 1, Digest.BUCKETS do
		buckets[i], counts[i], bytes[i] = 0, 0, 0
	end
	return { buckets = buckets, counts = counts, bytes = bytes, count = 0, bucketOf = {}, dirty = true }
end

-- A note's rough cost in a catch-up (§5.6): NOTE_BYTES, or its text length
-- when that's larger, so long notes and recipe lists (§9.2) aren't priced
-- like short ones.
function Sync.noteBytes(note)
	return math.max(Sync.NOTE_BYTES, #(note.text or ""))
end

-- The board's digest, bucket hashes, per-bucket note counts and bytes, cached.
-- Changes mark only their own buckets dirty, so a live edit rehashes one
-- bucket rather than the board (the Phase 3 digest-cost note).
function Sync:summary(board)
	local s = self.cache[board.id]
	if not s then
		s = emptySummary()
		self.cache[board.id] = s
	end
	if not s.dirty then
		return s
	end
	local all = s.dirty == true
	local lines, counts, bytes = {}, {}, {}
	for i = 1, Digest.BUCKETS do
		if all or s.dirty[i - 1] then
			lines[i], counts[i], bytes[i] = {}, 0, 0
		end
	end
	local total = 0
	for id, note in pairs(board.notes or {}) do
		local b = s.bucketOf[id]
		if not b then
			b = Digest.bucket(id)
			s.bucketOf[id] = b
		end
		local bucket = lines[b + 1]
		if bucket then
			bucket[#bucket + 1] = Digest.line(note)
			counts[b + 1] = counts[b + 1] + 1
			bytes[b + 1] = bytes[b + 1] + Sync.noteBytes(note)
		end
		total = total + 1
	end
	for i = 1, Digest.BUCKETS do
		if lines[i] then
			sort(lines[i], Util.less)
			s.buckets[i] = Util.fnv1a32(concat(lines[i]))
			s.counts[i] = counts[i]
			s.bytes[i] = bytes[i]
		end
	end
	s.count = total
	s.digest = Digest.combine(s.buckets)
	s.dirty = false
	return s
end

function Sync:invalidate(boardId, ids)
	local s = self.cache[boardId]
	if not s or s.dirty == true then
		return
	end
	if not ids then
		s.dirty = true
		return
	end
	s.dirty = s.dirty or {}
	for _, id in ipairs(ids) do
		local b = s.bucketOf[id] or Digest.bucket(id)
		s.bucketOf[id] = b
		s.dirty[b] = true
	end
end

-- A digest of the member list, the same way notes are hashed: sorted
-- "name=rev;editor" lines. It rides on HELLO so members sync too.
function Sync.membersDigest(members)
	local lines = {}
	for _, m in pairs(members or {}) do
		lines[#lines + 1] = m.name .. "=" .. Util.formatInt(m.rev) .. ";" .. m.editor .. "\n"
	end
	sort(lines, Util.less)
	return Util.fnv1a32(concat(lines))
end

-- Peers ---------------------------------------------------------------------------------

function Sync:peer(boardId, name)
	local peers = self.peers[boardId]
	if not peers then
		peers = {}
		self.peers[boardId] = peers
	end
	local peer = peers[name]
	if not peer then
		peer = { name = name }
		peers[name] = peer
	end
	return peer
end

function Sync:online(peer)
	return peer.heard ~= nil and self:time() - peer.heard <= Sync.PRESENCE
end

-- Members heard from recently, by name.
function Sync:onlineNames(boardId)
	local out = {}
	for name, peer in pairs(self.peers[boardId] or {}) do
		if self:online(peer) then
			out[#out + 1] = name
		end
	end
	sort(out, Util.less)
	return out
end

-- Our place in the reply order for a HELLO (§5.4). Every member ranks the
-- online members, requester excluded, by a hash of the HELLO's nonce and
-- their name, so they agree on the order without talking. The first in line
-- replies after RESPONDER_BASE; each later one waits one RESPONDER_STEP more,
-- by when it has normally seen the first reply and stood down.
function Sync:rank(boardId, requester, nonce)
	local me = self:me()
	local names = { me }
	for name, peer in pairs(self.peers[boardId] or {}) do
		if name ~= requester and name ~= me and self:online(peer) then
			names[#names + 1] = name
		end
	end
	local seed = Util.formatInt(nonce) .. "|"
	local keys = {}
	for _, name in ipairs(names) do
		keys[name] = Util.fnv1a32(seed .. name)
	end
	sort(names, function(a, b)
		if keys[a] ~= keys[b] then
			return keys[a] < keys[b]
		end
		return Util.less(a, b)
	end)
	for i, name in ipairs(names) do
		if name == me then
			return i - 1
		end
	end
	return 0
end

-- Whether the companion has synced this board recently enough that the cloud
-- can take a large catch-up (§5.6). A board with cloud sync on but no
-- companion yet still catches up in game.
function Sync:cloudActive(board)
	local at = board.cloud and board.sync and board.sync.lastCloudAt
	return at ~= nil and self.store.env.now() - at <= Sync.CLOUD_FRESH
end

-- Sending --------------------------------------------------------------------------------

function Sync:push(item)
	item.dest = item.dest or { board = item.board }
	local queued = self.outbox:push(item)
	self.outbox:pump()
	return queued
end

local function mergeIds(existing, new)
	for _, id in ipairs(new.order) do
		if not existing.ids[id] then
			existing.ids[id] = true
			existing.order[#existing.order + 1] = id
		end
	end
	if new.to then
		existing.to = new.to
	end
end

local function idSet(ids)
	local set, order = {}, {}
	for _, id in ipairs(ids) do
		if not set[id] then
			set[id] = true
			order[#order + 1] = id
		end
	end
	return set, order
end

-- A rough byte count for a note in a PUT, before compression.
local function noteBytes(note)
	return #note.text + #note.id + #note.author + #note.editor + 30
end

function Sync:buildPut(item)
	local board = self:board(item.board)
	if not board then
		return nil
	end
	local notes, bytes = {}, 0
	while #item.order > 0 do
		local id = item.order[1]
		local note = board.notes and board.notes[id]
		if note then
			local size = noteBytes(note)
			if #notes > 0 and bytes + size > Sync.PUT_BYTES then
				break
			end
			notes[#notes + 1] = note
			bytes = bytes + size
		end
		table.remove(item.order, 1)
		item.ids[id] = nil
	end
	if #notes == 0 then
		return nil
	end
	self:note("> PUT    %d notes  %s", #notes, item.prio)
	return { v = 1, t = "PUT", b = item.board, n = notes }, #item.order > 0
end

-- Queues notes to broadcast. Live edits go at ALERT; catch-up at NORMAL or
-- BULK. Items of one priority coalesce per board.
function Sync:pushPut(boardId, ids, prio)
	local set, order = idSet(ids)
	return self:push({
		prio = prio,
		key = "PUT:" .. prio .. ":" .. boardId,
		board = boardId,
		ids = set,
		order = order,
		merge = mergeIds,
		build = function(item)
			return self:buildPut(item)
		end,
	})
end

function Sync:buildHello(item)
	local board = self:board(item.board)
	if not board then
		return nil
	end
	local s = self:summary(board)
	local nonce = floor(self.env.random() * 2147483647)
	self.lastHello[board.id] = self:time()
	local me = self:me()
	self:note("> HELLO  %d notes", s.count)
	return {
		v = 1,
		t = "HELLO",
		b = board.id,
		r = nonce,
		d = s.digest,
		n = s.count,
		c = board.clock or 0,
		k = s.buckets,
		kc = s.counts,
		md = Sync.membersDigest(board.members),
		m = board.meta,
		me = me and board.members and board.members[me] or nil,
		cls = self.env.class,
		lvl = self.env.level,
		cl = self:cloudActive(board) and board.sync.lastCloudAt or false,
	}
end

function Sync:hello(boardId)
	if not self:board(boardId) then
		return
	end
	return self:push({
		prio = "NORMAL",
		key = "HELLO:" .. boardId,
		board = boardId,
		build = function(item)
			return self:buildHello(item)
		end,
	})
end

function Sync:helloAll()
	for id in pairs(self.store:all()) do
		self:hello(id)
	end
end

function Sync:buildMembers(item)
	local board = self:board(item.board)
	if not board then
		return nil
	end
	local names = {}
	for name in pairs(board.members or {}) do
		names[#names + 1] = name
	end
	sort(names, Util.less)
	local list = {}
	local first = item.offset or 1
	for i = first, math.min(#names, first + Sync.MEMBERS_PER - 1) do
		list[#list + 1] = board.members[names[i]]
	end
	item.offset = first + Sync.MEMBERS_PER
	if #list == 0 then
		return nil
	end
	self:note("> MEMBERS %d", #list)
	return { v = 1, t = "MEMBERS", b = board.id, m = list }, item.offset <= #names
end

function Sync:pushMembers(boardId)
	return self:push({
		prio = "NORMAL",
		key = "MEMBERS:" .. boardId,
		board = boardId,
		build = function(item)
			return self:buildMembers(item)
		end,
	})
end

function Sync:pushMeta(boardId)
	return self:push({
		prio = "NORMAL",
		key = "META:" .. boardId,
		board = boardId,
		build = function(item)
			local board = self:board(item.board)
			if not board or not board.meta then
				return nil
			end
			return { v = 1, t = "META", b = board.id, m = board.meta }
		end,
	})
end

-- The notes in the given buckets (0-31), by bucket.
function Sync:notesIn(board, buckets)
	local s = self:summary(board)
	local want = {}
	for _, b in ipairs(buckets) do
		want[b] = {}
	end
	for id, note in pairs(board.notes or {}) do
		local list = want[s.bucketOf[id]]
		if list then
			list[#list + 1] = note
		end
	end
	for _, list in pairs(want) do
		sort(list, function(a, b)
			return Util.less(a.id, b.id)
		end)
	end
	return want
end

local function entry(note)
	return { note.id, note.rev, note.editor }
end

function Sync:buildIdx(item)
	local board = self:board(item.board)
	if not board then
		return nil
	end
	local byBucket = self:notesIn(board, item.buckets)
	local entries = {}
	if item.partial then
		-- Only our newest notes in the differing buckets; the cloud brings
		-- the rest (§5.6).
		local all = {}
		for _, list in pairs(byBucket) do
			for _, note in ipairs(list) do
				all[#all + 1] = note
			end
		end
		sort(all, function(a, b)
			if a.rev ~= b.rev then
				return a.rev > b.rev
			end
			return Util.less(a.id, b.id)
		end)
		for i = 1, math.min(#all, Sync.PARTIAL) do
			entries[i] = entry(all[i])
		end
		self:note("> IDX    %s  newest %d of about %d", item.to, #entries, item.behind)
		return { v = 1, t = "IDX", b = board.id, to = item.to, r = item.nonce, p = 1, bh = item.behind, e = entries }
	end
	local taken = {}
	while #item.buckets > 0 do
		local b = table.remove(item.buckets, 1)
		taken[#taken + 1] = b
		for _, note in ipairs(byBucket[b]) do
			entries[#entries + 1] = entry(note)
		end
		if #entries >= Sync.IDX_ENTRIES then
			break
		end
	end
	self:note("> IDX    %s  buckets %s  %d ids", item.to, concat(taken, " "), #entries)
	return {
		v = 1,
		t = "IDX",
		b = board.id,
		to = item.to,
		r = item.nonce,
		bk = taken,
		e = entries,
		x = item.bulk and 1 or nil,
	}, #item.buckets > 0
end

-- Answers a HELLO whose digest differs from ours (§5.4, §5.6).
function Sync:pushIdx(boardId, requester, hello)
	local board = self:board(boardId)
	if not board then
		return
	end
	local mine = self:summary(board)
	local buckets = Digest.mismatched(mine.buckets, hello.k)
	if #buckets == 0 then
		return
	end
	local size, theirsBehind, oursBehind = 0, 0, 0
	for _, b in ipairs(buckets) do
		local ours, theirs = mine.counts[b + 1], hello.kc[b + 1]
		size = size + math.max(mine.bytes[b + 1], theirs * Sync.NOTE_BYTES)
		theirsBehind = theirsBehind + math.max(0, ours - theirs)
		oursBehind = oursBehind + math.max(0, theirs - ours)
	end
	local bulk = size > Sync.BULK_BYTES
	local partial = bulk and hello.cl ~= false and hello.cl ~= nil
	if bulk and oursBehind > theirsBehind then
		-- We're the stale one: ask for our own catch-up, under our own
		-- cloud setting, as well as answering.
		self:hello(boardId)
	end
	return self:push({
		prio = (bulk and not partial) and "BULK" or "NORMAL",
		key = "IDX:" .. boardId .. ":" .. requester,
		board = boardId,
		to = requester,
		nonce = hello.r,
		buckets = buckets,
		bulk = bulk and not partial,
		partial = partial,
		behind = math.max(theirsBehind, partial and 1 or 0),
		build = function(item)
			return self:buildIdx(item)
		end,
	})
end

function Sync:pushNeed(boardId, to, ids, bulk)
	local set, order = idSet(ids)
	return self:push({
		prio = bulk and "BULK" or "NORMAL",
		key = "NEED:" .. boardId .. ":" .. to,
		board = boardId,
		to = to,
		ids = set,
		order = order,
		merge = mergeIds,
		build = function(item)
			local list = {}
			while #item.order > 0 and #list < Sync.NEED_IDS do
				local id = table.remove(item.order, 1)
				item.ids[id] = nil
				list[#list + 1] = id
			end
			if #list == 0 then
				return nil
			end
			self:note("> NEED   %s  %d ids", item.to, #list)
			return { v = 1, t = "NEED", b = boardId, to = item.to, ids = list, x = bulk and 1 or nil },
				#item.order > 0
		end,
	})
end

-- Timers ------------------------------------------------------------------------------------

local function cancel(timer)
	if timer then
		timer:Cancel()
	end
end

function Sync:scheduleHello(boardId)
	cancel(self.helloTimers[boardId])
	local delay = Sync.HELLO_EVERY + (self.env.random() * 2 - 1) * Sync.HELLO_JITTER
	self.helloTimers[boardId] = self.env.after(delay, function()
		self.helloTimers[boardId] = nil
		if not self:board(boardId) then
			return
		end
		local last = self.lastHello[boardId]
		-- Skip when the board was just discussed, but never twice running,
		-- so every member still announces itself now and then.
		if last and self:time() - last < Sync.HELLO_QUIET and not self.skipped[boardId] then
			self.skipped[boardId] = true
		else
			self.skipped[boardId] = false
			self:hello(boardId)
		end
		self:scheduleHello(boardId)
	end)
end

-- Starts the periodic HELLOs and says HELLO on every board (login).
function Sync:start()
	for id in pairs(self.store:all()) do
		self:scheduleHello(id)
		self:hello(id)
	end
end

function Sync:scheduleResponder(boardId, requester, hello)
	local key = boardId .. "\0" .. requester
	cancel(self.responders[key])
	self.outbox:cancel("IDX:" .. boardId .. ":" .. requester)
	local rank = math.min(self:rank(boardId, requester, hello.r), Sync.RESPONDER_RANKS)
	local delay = Sync.RESPONDER_BASE + rank * Sync.RESPONDER_STEP + self.env.random() * Sync.RESPONDER_JITTER
	self.responders[key] = self.env.after(delay, function()
		self.responders[key] = nil
		self:pushIdx(boardId, requester, hello)
	end)
end

-- Someone else answered `requester` (§5.4): stand down.
function Sync:standDown(boardId, requester)
	local key = boardId .. "\0" .. requester
	if self.responders[key] then
		cancel(self.responders[key])
		self.responders[key] = nil
		self:note("= stood down for %s", requester)
	end
	self.outbox:cancel("IDX:" .. boardId .. ":" .. requester)
end

-- Sends our member list or board name after a short random delay, unless
-- another member sends theirs first (the MEMBERS and META handlers cancel it).
function Sync:scheduleOnce(timers, key, push, boardId)
	if timers[boardId] or self.outbox:queued(key .. boardId) then
		return
	end
	local delay = Sync.MEMBERS_DELAY + self.env.random() * Sync.MEMBERS_SPREAD
	timers[boardId] = self.env.after(delay, function()
		timers[boardId] = nil
		push(self, boardId)
	end)
end

function Sync:scheduleMembers(boardId)
	self:scheduleOnce(self.membersTimers, "MEMBERS:", Sync.pushMembers, boardId)
end

-- A HELLO showed an older board name, or none: send ours unless another
-- member does first.
function Sync:scheduleMeta(boardId)
	self:scheduleOnce(self.metaTimers, "META:", Sync.pushMeta, boardId)
end

-- Records that this board now matches `name`'s copy, for the status line.
function Sync:syncedWith(board, name)
	board.sync = board.sync or {}
	board.sync.lastPeer, board.sync.lastPeerAt = name, self.store.env.now()
	self.behind[board.id] = nil
	if self.env.synced then
		self.env.synced(board.id)
	end
end

-- Receiving ------------------------------------------------------------------------------------

local function isInt(n, min, max)
	return Util.isInteger(n, min or 0, max or Util.INT_MAX)
end

local function isList(t, max)
	return type(t) == "table" and #t <= (max or Sync.MAX_LIST)
end

local function uint32List(t)
	if type(t) ~= "table" then
		return false
	end
	for i = 1, Digest.BUCKETS do
		if not isInt(t[i], 0, 4294967295) then
			return false
		end
	end
	return true
end

local handlers = {}

function handlers.HELLO(self, board, e, sender)
	if not (isInt(e.r) and isInt(e.d, 0, 4294967295) and isInt(e.n) and isInt(e.c) and isInt(e.md, 0, 4294967295)
		and uint32List(e.k) and uint32List(e.kc)) then
		return false
	end
	local peer = self:peer(board.id, sender)
	peer.hello, peer.digest, peer.count, peer.clock = self:time(), e.d, e.n, e.c
	peer.buckets, peer.counts = e.k, e.kc
	peer.cloud = type(e.cl) == "number" and e.cl or nil
	if type(e.cls) == "string" then
		peer.class = e.cls
	end
	if isInt(e.lvl, 1, Store.MAX_LEVEL) then
		peer.level = e.lvl
	end
	self.lastHello[board.id] = self:time()
	-- A HELLO carries the board name and the sender's own member record.
	local records = { meta = type(e.m) == "table" and e.m or nil }
	if type(e.me) == "table" and e.me.name == sender then
		records.members = { e.me }
	end
	self:merge(board, records, sender)
	if e.md ~= Sync.membersDigest(board.members) then
		self:scheduleMembers(board.id)
	end
	local theirs = records.meta and Sanitise.meta(records.meta)
	if board.meta and (not theirs or Merge.compareMeta(board.meta, theirs) > 0) then
		self:scheduleMeta(board.id)
	end
	local mine = self:summary(board)
	if e.d == mine.digest then
		peer.state = "match"
		self:syncedWith(board, sender)
		self:note("< HELLO  %s  %d notes  matches", sender, e.n)
		self:standDown(board.id, sender)
	else
		peer.state = "differs"
		self:note("< HELLO  %s  %d notes  differs", sender, e.n)
		self:scheduleResponder(board.id, sender, e)
	end
	return true
end

function handlers.IDX(self, board, e, sender)
	if type(e.to) ~= "string" or not isList(e.e) then
		return false
	end
	if e.to ~= self:me() then
		self:standDown(board.id, e.to)
		return true
	end
	local need, listed = {}, {}
	for _, item in ipairs(e.e) do
		local id, rev, editor = item[1], item[2], item[3]
		if not (Sanitise.noteId(id) and isInt(rev, 1) and Sanitise.name(editor)) then
			return false
		end
		local version = { rev = rev, editor = editor }
		listed[id] = version
		local mine = board.notes and board.notes[id]
		if not mine or Merge.compareVersion(mine, version) < 0 then
			need[#need + 1] = id
		end
	end
	local bulk = e.x ~= nil
	local push = {}
	if e.p then
		local behind = isInt(e.bh) and e.bh or 0
		if behind > 0 then
			self.behind[board.id] = { count = behind, at = self.store.env.now() }
		end
	elseif isList(e.bk, Digest.BUCKETS) then
		local covered = {}
		for _, b in ipairs(e.bk) do
			if not isInt(b, 0, Digest.BUCKETS - 1) then
				return false
			end
			covered[b] = true
		end
		local s = self:summary(board)
		for id, note in pairs(board.notes or {}) do
			if covered[s.bucketOf[id]] then
				local theirs = listed[id]
				if not theirs or Merge.compareVersion(note, theirs) > 0 then
					push[#push + 1] = id
				end
			end
		end
		sort(push, Util.less)
	end
	self:note("< IDX    %s  %d ids  need %d, push %d", sender, #e.e, #need, #push)
	if #need > 0 then
		local set = {}
		for _, id in ipairs(need) do
			set[id] = true
		end
		self.syncing[board.id] = { from = sender, want = set, left = #need, at = self:time() }
		self:pushNeed(board.id, sender, need, bulk)
	end
	if #push > 0 then
		self:pushPut(board.id, push, bulk and "BULK" or "NORMAL")
	end
	if #need == 0 and #push == 0 and not e.p then
		self:syncedWith(board, sender) -- nothing to exchange in the buckets that differed
	end
	self:changed(board.id)
	return true
end

function handlers.NEED(self, board, e, sender)
	if type(e.to) ~= "string" or not isList(e.ids) then
		return false
	end
	if e.to ~= self:me() then
		return true
	end
	local ids = {}
	for _, id in ipairs(e.ids) do
		if not Sanitise.noteId(id) then
			return false
		end
		if board.notes and board.notes[id] then
			ids[#ids + 1] = id
		end
	end
	self:note("< NEED   %s  %d ids", sender, #e.ids)
	if #ids > 0 then
		self:pushPut(board.id, ids, e.x and "BULK" or "NORMAL")
	end
	return true
end

function handlers.PUT(self, board, e, sender)
	if not isList(e.n) then
		return false
	end
	local result = self:merge(board, { notes = e.n }, sender)
	self:note("< PUT    %s  %d notes  merged %d", sender, #e.n, #result.notes)
	local syncing = self.syncing[board.id]
	if syncing then
		for _, note in ipairs(e.n) do
			if type(note) == "table" and syncing.want[note.id] then
				syncing.want[note.id] = nil
				syncing.left = syncing.left - 1
			end
		end
		if syncing.left <= 0 then
			self.syncing[board.id] = nil
			if not self.behind[board.id] then
				self:syncedWith(board, syncing.from) -- caught up with them
			end
		end
	end
	return true
end

function handlers.MEMBERS(self, board, e, sender)
	if not isList(e.m) then
		return false
	end
	-- Someone has sent the list: don't send ours too, unless it still
	-- holds something theirs lacks.
	cancel(self.membersTimers[board.id])
	self.membersTimers[board.id] = nil
	self.outbox:cancel("MEMBERS:" .. board.id)
	local theirs = {}
	for _, m in ipairs(e.m) do
		local clean = Sanitise.member(m)
		if clean then
			theirs[#theirs + 1] = clean
		end
	end
	local result = self:merge(board, { members = theirs }, sender)
	self:note("< MEMBERS %s  %d  merged %d", sender, #e.m, #result.members)
	if #e.m < Sync.MEMBERS_PER and Sync.membersDigest(theirs) ~= Sync.membersDigest(board.members) then
		self:scheduleMembers(board.id)
	end
	return true
end

function handlers.META(self, board, e, sender)
	if type(e.m) ~= "table" then
		return false
	end
	self:merge(board, { meta = e.m }, sender)
	-- Stand down unless ours is still newer.
	local theirs = Sanitise.meta(e.m)
	if theirs and board.meta and Merge.compareMeta(board.meta, theirs) <= 0 then
		cancel(self.metaTimers[board.id])
		self.metaTimers[board.id] = nil
		self.outbox:cancel("META:" .. board.id)
	end
	return true
end

function Sync:merge(board, records, sender)
	local result = self.store:applyRemote(board.id, records)
	local stored = #result.notes + #result.members + (result.meta and 1 or 0)
	self.stats.merged = self.stats.merged + stored
	if #result.dropped > 0 then
		self:note("! dropped %d records from %s (%s)", #result.dropped, sender, concat(result.dropped, ", "))
	end
	return result
end

-- One decoded envelope from `sender` ("Name-Realm"). The transport has
-- already checked it arrived on the board's own channel (or GUILD for a
-- guild board). Returns true if it was handled.
function Sync:receive(envelope, sender)
	self.stats.received = self.stats.received + 1
	local board = self:board(envelope.b)
	local handler = handlers[envelope.t]
	if not board or not handler or sender == self:me() then
		self.stats.ignored = self.stats.ignored + 1
		return false
	end
	local member = board.members and board.members[sender]
	if member and member.removed then
		self.stats.ignored = self.stats.ignored + 1
		self:note("! ignored %s from %s (removed)", envelope.t, sender)
		return false
	end
	local peer = self:peer(board.id, sender)
	peer.heard = self:time()
	Store.markSeen(board, sender, envelope.cls or peer.class, self.store.env.now(), envelope.lvl or peer.level)
	local ok, result = pcall(handler, self, board, envelope, sender)
	if not ok or not result then
		self.stats.malformed = self.stats.malformed + 1
		self.stats.lastError = not ok and tostring(result) or envelope.t
		self:note("! malformed %s from %s", envelope.t, sender)
		return false
	end
	self:changed(board.id)
	return true
end

-- Store changes ------------------------------------------------------------------------------

function Sync:onChange(change)
	local id = change.board
	if change.kind == "deleted" then
		self:forget(id)
		return
	end
	if change.kind == "note" then
		self:invalidate(id, change.keys)
		if not change.remote then
			self:pushPut(id, change.keys, "ALERT")
		end
	elseif change.kind == "member" then
		if not change.remote then
			self:pushMembers(id)
		end
	elseif change.kind == "meta" then
		if not change.remote then
			self:pushMeta(id)
		end
	elseif change.kind == "board" then
		self:invalidate(id)
		if not self.helloTimers[id] then
			self:scheduleHello(id)
		end
		self:hello(id)
	end
	self:changed(id)
end

-- Drops everything about a board deleted from this account.
function Sync:forget(boardId)
	cancel(self.helloTimers[boardId])
	cancel(self.membersTimers[boardId])
	cancel(self.metaTimers[boardId])
	self.helloTimers[boardId], self.membersTimers[boardId], self.metaTimers[boardId] = nil, nil, nil
	for key, timer in pairs(self.responders) do
		if key:sub(1, #boardId + 1) == boardId .. "\0" then
			cancel(timer)
			self.responders[key] = nil
		end
	end
	self.outbox:cancelBoard(boardId)
	self.peers[boardId], self.cache[boardId], self.syncing[boardId], self.behind[boardId] = nil, nil, nil, nil
	self.lastHello[boardId], self.skipped[boardId] = nil, nil
end

-- The gate opened again (§5.5): the outbox flushes, and every board says HELLO.
function Sync:onGateOpen()
	self:note("= send gate open")
	self:helloAll()
end

-- For the UI ------------------------------------------------------------------------------

-- What the status line and roster need about one board.
function Sync:status(boardId)
	local board = self:board(boardId)
	if not board then
		return nil
	end
	local syncing = self.syncing[boardId]
	if syncing and self:time() - syncing.at > Sync.SYNCING then
		self.syncing[boardId], syncing = nil, nil
	end
	local sync = board.sync or {}
	return {
		online = self:onlineNames(boardId),
		queued = self.outbox:depth(boardId),
		paused = not self.outbox.gate.open,
		syncing = syncing and { from = syncing.from, left = syncing.left } or nil,
		behind = self.behind[boardId] and self.behind[boardId].count or nil,
		lastPeer = sync.lastPeer,
		lastPeerAt = sync.lastPeerAt,
		lastCloudAt = sync.lastCloudAt,
		cloud = board.cloud,
	}
end

ns.Sync = Sync
return Sync
