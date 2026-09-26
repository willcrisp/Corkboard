-- The board store (docs/design.md §4). Boards live in the AceDB table
-- CorkboardDB.global.boards, and every change to a board goes through the
-- merge core. Pure Lua 5.1: the WoW side comes in through `db` (the AceDB
-- object, or any table with `global` and `char`) and `env`:
--
--   env.now()    GetServerTime()
--   env.rand(n)  a random integer from 1 to n
--   env.me       the player's "Name-Realm", or nil while it isn't known
--   env.prefix   Store.notePrefix(UnitGUID("player")), or nil likewise
--   env.questTitle(id)  a quest's title, or nil while the client doesn't know
--                it (optional; /cork quests falls back to "Quest #id")

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Merge = ns.Merge or require("Core.Merge")
local Invite = ns.Invite or require("Core.Invite")

local format, gmatch, lower, match, sub = string.format, string.gmatch, string.lower, string.match, string.sub
local floor = math.floor
local concat, sort = table.concat, table.sort

local Store = {}
Store.__index = Store

Store.ID_LENGTH = 16
Store.SECRET_LENGTH = 24
-- Keeps a note id within Sanitise.MAX_ID: 8 hex, "-", 9 digits.
Store.MAX_COUNTER = 999999999

local BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"

function Store.randomString(rand, length)
	local out = {}
	for i = 1, length do
		local k = rand(36)
		out[i] = sub(BASE36, k, k)
	end
	return table.concat(out)
end

-- The note-id prefix (§4.2): 8 lower-case hex digits of FNV-1a over the
-- player's GUID. The same character gets the same prefix on every install.
function Store.notePrefix(guid)
	return format("%08x", Util.fnv1a32(guid))
end

local function counter(id)
	return tonumber(match(id, "%-(%d+)$"))
end

-- The next note id for `prefix` on this board (§4.2): one more than the
-- highest counter any note with this prefix has, tombstones included. The
-- counter comes from the board, not from this install, so one character
-- playing on two computers doesn't reuse an id once the board has synced.
function Store.nextNoteId(board, prefix)
	local highest = 0
	for id in pairs(board.notes or {}) do
		if sub(id, 1, 9) == prefix .. "-" then
			local n = counter(id)
			if n > highest then
				highest = n
			end
		end
	end
	if highest >= Store.MAX_COUNTER then
		return nil, "id_space"
	end
	return format("%s-%04.0f", prefix, highest + 1)
end

function Store.new(db, env)
	return setmetatable({ db = db, env = env, listeners = {} }, Store)
end

-- Change notifications, for the sync engine and the window. Each listener is
-- called as fn(change) with change = { board = id, kind, keys, remote }:
--   kind "note", "member" or "meta": keys lists the note ids or member names
--     stored; remote is true when the change arrived from a peer or the cloud.
--   kind "board": the board was created or joined, or its secret or options
--     changed. kind "deleted": it was removed from this account.
function Store:listen(fn)
	self.listeners[#self.listeners + 1] = fn
end

function Store:notify(boardId, kind, keys, remote)
	local change = { board = boardId, kind = kind, keys = keys or {}, remote = remote or false }
	for _, fn in ipairs(self.listeners) do
		fn(change)
	end
end

function Store:all()
	return self.db.global.boards
end

function Store:board(id)
	local board = id and self:all()[id]
	if not board then
		return nil, "missing"
	end
	return board
end

function Store.name(board)
	return board.meta and board.meta.name or board.id
end

-- A board as this account first holds it, before any meta or members.
local function newBoard(id, secret, owner, now)
	return {
		id = id,
		secret = secret,
		owner = owner,
		created = now,
		clock = 0,
		notes = {},
		members = {},
		sync = {},
		cloud = true,
		guild = false,
		gear = true,
		quests = true,
	}
end

local function me(self)
	local name = self.env.me
	if not name or not self.env.prefix then
		return nil, "identity"
	end
	return name
end

-- Boards ---------------------------------------------------------------------

-- Creates a board owned by the player and makes it the current one.
function Store:createBoard(name)
	local owner, reason = me(self)
	if not owner then
		return nil, reason
	end
	local rand, now, boards = self.env.rand, self.env.now(), self:all()
	local id
	repeat
		id = Store.randomString(rand, Store.ID_LENGTH)
	until not boards[id]
	local board = newBoard(id, Store.randomString(rand, Store.SECRET_LENGTH), owner, now)
	local ok
	ok, reason = Merge.setMeta(board, name, owner, now)
	if not ok then
		return nil, reason
	end
	assert(Merge.setMember(board, owner, "owner", false, owner, now))
	boards[id] = board
	self.db.char.current = id
	self:notify(id, "board")
	self:shareQuests(id)
	return board
end

function Store:renameBoard(id, name)
	local editor, reason = me(self)
	if not editor then
		return nil, reason
	end
	local board
	board, reason = self:board(id)
	if not board then
		return nil, reason
	end
	local meta
	meta, reason = Merge.setMeta(board, name, editor, self.env.now())
	if meta then
		self:notify(id, "meta")
	end
	return meta, reason
end

-- Removes the board from this account only. It isn't a merge: other members
-- keep their copies, and without the secret this client can't hear the board
-- again until someone re-invites it.
function Store:deleteBoard(id)
	local board, reason = self:board(id)
	if not board then
		return nil, reason
	end
	self:all()[id] = nil
	if self.db.char.current == id then
		self.db.char.current = nil
	end
	self:notify(id, "deleted")
	return board
end

-- Boards sorted by name (ASCII case folded, then byte-wise), then id.
function Store:boards()
	local list = {}
	for _, board in pairs(self:all()) do
		list[#list + 1] = board
	end
	sort(list, function(a, b)
		local c = Util.compare(lower(Store.name(a)), lower(Store.name(b)))
		if c ~= 0 then
			return c < 0
		end
		return Util.less(a.id, b.id)
	end)
	return list
end

function Store:current()
	local id = self.db.char.current
	return id and self:all()[id] or nil
end

function Store:select(id)
	local board, reason = self:board(id)
	if not board then
		return nil, reason
	end
	self.db.char.current = id
	return board
end

-- Notes ------------------------------------------------------------------------

-- Live notes, oldest first (by created, then id). Gear-feed entries (§9.1)
-- are listed by Store.gear instead.
function Store.notes(board)
	local list = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted and note.kind == nil then
			list[#list + 1] = note
		end
	end
	sort(list, function(a, b)
		if a.created ~= b.created then
			return a.created < b.created
		end
		return Util.less(a.id, b.id)
	end)
	return list
end

local function noteChange(self, boardId)
	local editor, reason = me(self)
	if not editor then
		return nil, reason
	end
	local board
	board, reason = self:board(boardId)
	if not board then
		return nil, reason
	end
	return board, editor
end

-- Passes a local note change through, notifying listeners when it happened.
function Store:noted(board, note, reason)
	if note then
		self:notify(board.id, "note", { note.id })
	end
	return note, reason
end

function Store:addNote(boardId, text, color)
	local board, author = noteChange(self, boardId)
	if not board then
		return nil, author
	end
	local id, reason = Store.nextNoteId(board, self.env.prefix)
	if not id then
		return nil, reason
	end
	return self:noted(board, Merge.createNote(board, { id = id, author = author, text = text, color = color },
		self.env.now()))
end

-- changes: text and/or color.
function Store:editNote(boardId, noteId, changes)
	local board, editor = noteChange(self, boardId)
	if not board then
		return nil, editor
	end
	return self:noted(board, Merge.editNote(board, noteId, changes, editor, self.env.now()))
end

function Store:deleteNote(boardId, noteId)
	local board, editor = noteChange(self, boardId)
	if not board then
		return nil, editor
	end
	return self:noted(board, Merge.deleteNote(board, noteId, editor, self.env.now()))
end

-- Gear feed (§9.1) --------------------------------------------------------------

Store.GEAR_QUALITY = 3 -- Enum.ItemQuality.Rare: blue and better are posted
Store.GEAR_SHOWN = 50 -- entries on the Gear tab

-- Live gear entries, newest first (by created, then id).
function Store.gear(board)
	local list = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted and note.kind == "gear" then
			list[#list + 1] = note
		end
	end
	sort(list, function(a, b)
		if a.created ~= b.created then
			return a.created > b.created
		end
		return Util.less(b.id, a.id)
	end)
	return list
end

-- The player equipped an item. The first time this character equips a given
-- item, and only if it's rare or better, its link goes to the gear feed of
-- every board with gear posts on (board.gear, local, on by default) that
-- hasn't removed the player. `seed` marks the item seen without posting: the
-- addon seeds what's already equipped at login. Returns how many boards got
-- an entry, or nil and a reason.
function Store:equipped(itemId, link, quality, seed)
	local author, reason = me(self)
	if not author then
		return nil, reason
	end
	local seen = self.db.char.gearSeen
	if not seen then
		seen = {}
		self.db.char.gearSeen = seen
	end
	if seen[itemId] then
		return 0
	end
	seen[itemId] = true
	if seed or (quality or 0) < Store.GEAR_QUALITY then
		return 0
	end
	local posted = 0
	for _, board in pairs(self:all()) do
		local mine = board.members and board.members[author]
		if board.gear ~= false and not (mine and mine.removed) then
			local id = Store.nextNoteId(board, self.env.prefix)
			if id and self:noted(board, Merge.createNote(board, { id = id, author = author, text = link, kind = "gear" },
				self.env.now())) then
				posted = posted + 1
			end
		end
	end
	return posted
end

-- Quest logs (§9.2) ------------------------------------------------------------

Store.QUESTS_MAX = 50 -- quests kept from one log; Forever's quest log holds 40
local MAX_QUEST_ID = 999999999
local MAX_QUEST_LEVEL = 999

local function questNumber(value, low, high)
	value = tonumber(value)
	if value and value == floor(value) and value >= low and value <= high then
		return value
	end
end

-- A quest log as note text: "id:level" pairs joined by commas, by id, so the
-- same log always gives the same text. Only ids and levels travel, which
-- keeps a full log of 40 quests near 400 bytes; each client shows titles
-- from its own quest data. Invalid and repeated ids are skipped.
function Store.encodeQuests(quests)
	local levels, ids = {}, {}
	for _, quest in ipairs(quests) do
		local id = questNumber(quest.id, 1, MAX_QUEST_ID)
		if id and not levels[id] then
			levels[id] = questNumber(quest.level, 0, MAX_QUEST_LEVEL) or 0
			ids[#ids + 1] = id
		end
	end
	sort(ids)
	local parts = {}
	for i = 1, math.min(#ids, Store.QUESTS_MAX) do
		parts[i] = format("%d:%d", ids[i], levels[ids[i]])
	end
	return concat(parts, ",")
end

-- The quests in a log's text, as { id, level } in the order stored. Anything
-- that isn't an "id:level" pair (a newer client's extra fields) is skipped.
function Store.decodeQuests(text)
	local quests = {}
	for id, level in gmatch(text or "", "(%d+):(%d+)") do
		id, level = questNumber(id, 1, MAX_QUEST_ID), questNumber(level, 0, MAX_QUEST_LEVEL)
		if id and level then
			quests[#quests + 1] = { id = id, level = level }
			if #quests >= Store.QUESTS_MAX then
				break
			end
		end
	end
	return quests
end

-- The id of a character's quest log on every board: its note-id prefix with
-- counter 0. Store.nextNoteId starts ordinary notes at 1, so the log never
-- takes the id of a real note, even on an install that hasn't synced the
-- board yet. And every install of the character writes the same record, so
-- last-writer-wins keeps exactly one log per character.
function Store.questLogId(prefix)
	return prefix .. "-0"
end

-- Each character's quest log on the board: author -> its quest-log note.
-- Should two ever exist for one author, the newer (by rev, editor) counts.
function Store.questLogs(board)
	local logs = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted and note.kind == "quests" then
			local held = logs[note.author]
			if not held or Merge.compareVersion(note, held) > 0 then
				logs[note.author] = note
			end
		end
	end
	return logs
end

-- This character's own quests (id -> true), whether or not it shares them.
function Store:myQuests()
	local mine = {}
	for _, quest in ipairs(Store.decodeQuests(self.db.char.quests)) do
		mine[quest.id] = true
	end
	return mine
end

-- Brings this character's quest log on one board in line with the board's
-- option (board.quests, local, on by default): the latest log while sharing
-- is on and the board hasn't removed the player, a tombstone otherwise. An
-- unchanged log writes nothing. Returns true when it changed the board.
function Store:shareQuests(boardId)
	local author = me(self)
	local board = author and self:all()[boardId]
	if not board then
		return false
	end
	local id = Store.questLogId(self.env.prefix)
	local note = board.notes and board.notes[id]
	local text = self.db.char.quests
	local mine = board.members and board.members[author]
	local now = self.env.now()
	if text == nil or board.quests == false or (mine and mine.removed) then
		if note and not note.deleted then
			return self:noted(board, Merge.deleteNote(board, id, author, now)) ~= nil
		end
		return false
	end
	if not note then
		return self:noted(board, Merge.createNote(board, { id = id, author = author, text = text, kind = "quests" },
			now)) ~= nil
	elseif note.deleted then
		-- Sharing again after turning it off. A newer live version beats the
		-- tombstone under plain last-writer-wins (§4.3), here and on every peer.
		local stored = Merge.applyNote(board, {
			id = id,
			author = author,
			created = note.created,
			rev = Merge.nextRev(board, now),
			editor = author,
			text = text,
			color = note.color,
			deleted = false,
			kind = "quests",
		})
		if stored then
			self:notify(board.id, "note", { id })
		end
		return stored
	elseif note.text ~= text then
		return self:noted(board, Merge.editNote(board, id, { text = text }, author, now)) ~= nil
	end
	return false
end

-- The player's quest log, read from the client: a list of { id, level }.
-- It's kept for this character (so the Quests tab can mark the quests you
-- share), then published to every board with sharing on. Returns how many
-- boards changed and whether the log did, or nil and a reason while the
-- player's name isn't known (the log is still kept).
function Store:questLog(quests)
	local text = Store.encodeQuests(quests)
	local logChanged = self.db.char.quests ~= text
	self.db.char.quests = text
	local _, reason = me(self)
	if reason then
		return nil, reason
	end
	local changed = 0
	for id in pairs(self:all()) do
		if self:shareQuests(id) then
			changed = changed + 1
		end
	end
	return changed, logChanged
end

-- Sharing and members (§4.1, §9, §10) -------------------------------------------

-- The board's hidden channel (§5.1): "Cork" and 8 hex digits of FNV-1a over
-- the id and secret. The secret is the channel password too. Deriving the
-- name from the secret as well as the id moves the board to a fresh channel
-- when the secret rotates; otherwise a removed member still sitting in the
-- old channel would keep it (and its old password) alive, and everyone
-- rejoining with the new password would be refused.
function Store.channelName(board)
	return format("Cork%08x", Util.fnv1a32(board.id .. "|" .. board.secret))
end

-- Joins a board from a pasted invite and makes it the current board. Joining a
-- board this account already has takes the invite's secret, which is how a
-- member picks up a rotated one. Returns the board and whether it was new, or
-- nil and a reason.
function Store:joinBoard(text)
	local player, reason = me(self)
	if not player then
		return nil, reason
	end
	local invite
	invite, reason = Invite.decode(text)
	if not invite then
		return nil, reason
	end
	local now, boards = self.env.now(), self:all()
	local board, new = boards[invite.id], false
	if not board then
		new = true
		board = newBoard(invite.id, invite.secret, invite.owner, now)
		boards[invite.id] = board
	elseif board.secret ~= invite.secret then
		Store.retire(board, board.secret)
		board.secret = invite.secret
	end
	-- A fresh invite is worth another try at the channel, even if the last
	-- password was refused.
	board.sync = board.sync or {}
	board.sync.expired = nil
	local mine = board.members and board.members[player]
	if not mine or mine.removed then
		assert(Merge.setMember(board, player, player == board.owner and "owner" or "member", false, player, now))
		self:notify(board.id, "member", { player })
	end
	self.db.char.current = board.id
	self:notify(board.id, "board")
	self:shareQuests(board.id)
	return board, new
end

-- Remembers a secret the board no longer uses. The companion tries these to
-- rotate the board's cloud credential (§7.3) after a rotation.
function Store.retire(board, secret)
	board.oldSecrets = board.oldSecrets or {}
	for _, old in ipairs(board.oldSecrets) do
		if old == secret then
			return
		end
	end
	table.insert(board.oldSecrets, 1, secret)
	while #board.oldSecrets > 5 do
		table.remove(board.oldSecrets)
	end
end

function Store:isOwner(board)
	return board.owner == self.env.me
end

-- A new secret (§10): a new channel password and cloud credential. Only the
-- owner rotates, and every member they keep needs the new invite.
function Store:rotateSecret(boardId)
	local board, reason = self:board(boardId)
	if not board then
		return nil, reason
	end
	if not self:isOwner(board) then
		return nil, "not_owner"
	end
	local secret
	repeat
		secret = Store.randomString(self.env.rand, Store.SECRET_LENGTH)
	until secret ~= board.secret
	Store.retire(board, board.secret)
	board.secret = secret
	self:notify(boardId, "board")
	return board
end

-- Removes a member (the owner only), then rotates the secret so the removed
-- member can't reach the board's channel or cloud copy again.
function Store:removeMember(boardId, name)
	local editor, reason = me(self)
	if not editor then
		return nil, reason
	end
	local board
	board, reason = self:board(boardId)
	if not board then
		return nil, reason
	end
	if not self:isOwner(board) then
		return nil, "not_owner"
	end
	if name == editor then
		return nil, "remove_self"
	end
	local member = board.members and board.members[name]
	if not member or member.removed then
		return nil, "not_member"
	end
	local record
	record, reason = Merge.setMember(board, name, member.role, true, editor, self.env.now())
	if not record then
		return nil, reason
	end
	self:notify(boardId, "member", { name })
	self:rotateSecret(boardId)
	return record
end

-- Current members, owners first, then by name (byte-wise).
function Store.members(board)
	local list = {}
	for _, member in pairs(board.members or {}) do
		if not member.removed then
			list[#list + 1] = member
		end
	end
	sort(list, function(a, b)
		if a.role ~= b.role then
			return a.role == "owner"
		end
		return Util.less(a.name, b.name)
	end)
	return list
end

-- Cloud sync, the GUILD transport, gear posts and quest-log sharing, per
-- board (§4.1).
local OPTIONS = { cloud = true, guild = true, gear = true, quests = true }

function Store:setOption(boardId, option, value)
	local board, reason = self:board(boardId)
	if not board then
		return nil, reason
	end
	if not OPTIONS[option] then
		return nil, "option"
	end
	board[option] = value and true or false
	self:notify(boardId, "board")
	if option == "quests" then
		self:shareQuests(boardId) -- publishes the log, or deletes it when turned off
	end
	return board
end

-- Local-only bookkeeping for the roster: when each member was last heard
-- from, and their class for colouring. Never replicated.
function Store.markSeen(board, name, class, now)
	board.seen = board.seen or {}
	local seen = board.seen[name] or {}
	board.seen[name] = seen
	seen.at = now
	if type(class) == "string" and class:match("^%u+$") then
		seen.class = class
	end
end

-- Records from a peer or the cloud. `records` holds any of notes (list),
-- members (list) and meta. Returns the note ids and member names stored,
-- whether the meta was, and the reasons for any records dropped.
function Store:applyRemote(boardId, records)
	local board = self:all()[boardId]
	if not board then
		return nil, "missing"
	end
	local notes, dropped = Merge.applyNotes(board, records.notes or {})
	local members, droppedMembers = Merge.applyMembers(board, records.members or {})
	for _, reason in ipairs(droppedMembers) do
		dropped[#dropped + 1] = reason
	end
	local meta = false
	if records.meta ~= nil then
		local ok, reason = Merge.applyMeta(board, records.meta)
		meta = ok and true or false
		if not ok and reason ~= "stale" then
			dropped[#dropped + 1] = reason
		end
	end
	if #notes > 0 then
		self:notify(boardId, "note", notes, true)
	end
	if #members > 0 then
		self:notify(boardId, "member", members, true)
	end
	if meta then
		self:notify(boardId, "meta", nil, true)
	end
	return { notes = notes, members = members, meta = meta, dropped = dropped }
end

ns.Store = Store
return Store
