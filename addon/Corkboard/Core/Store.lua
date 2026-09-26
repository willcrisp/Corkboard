-- The board store (docs/design.md §4). Boards live in the AceDB table
-- CorkboardDB.global.boards, and every change to a board goes through the
-- merge core. Pure Lua 5.1: the WoW side comes in through `db` (the AceDB
-- object, or any table with `global` and `char`) and `env`:
--
--   env.now()    GetServerTime()
--   env.rand(n)  a random integer from 1 to n
--   env.me       the player's "Name-Realm", or nil while it isn't known
--   env.prefix   Store.notePrefix(UnitGUID("player")), or nil likewise

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Merge = ns.Merge or require("Core.Merge")
local Invite = ns.Invite or require("Core.Invite")

local format, lower, match, sub = string.format, string.lower, string.match, string.sub
local sort = table.sort

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
	local board = {
		id = id,
		secret = Store.randomString(rand, Store.SECRET_LENGTH),
		owner = owner,
		created = now,
		clock = 0,
		notes = {},
		members = {},
		sync = {},
		cloud = true,
		guild = false,
	}
	local ok
	ok, reason = Merge.setMeta(board, name, owner, now)
	if not ok then
		return nil, reason
	end
	assert(Merge.setMember(board, owner, "owner", false, owner, now))
	boards[id] = board
	self.db.char.current = id
	self:notify(id, "board")
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

-- Finds a board by exact id, then by name (ASCII case folded), then by id
-- prefix. Returns the board, or nil and "missing" or "ambiguous".
function Store:findBoard(query)
	local boards = self:all()
	if boards[query] then
		return boards[query]
	end
	local byName, byPrefix = {}, {}
	local wanted = lower(query)
	for id, board in pairs(boards) do
		if lower(Store.name(board)) == wanted then
			byName[#byName + 1] = board
		end
		if query ~= "" and sub(id, 1, #query) == query then
			byPrefix[#byPrefix + 1] = board
		end
	end
	for _, found in ipairs({ byName, byPrefix }) do
		if #found == 1 then
			return found[1]
		elseif #found > 1 then
			return nil, "ambiguous"
		end
	end
	return nil, "missing"
end

-- Notes ------------------------------------------------------------------------

-- Live notes, oldest first (by created, then id).
function Store.notes(board)
	local list = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted then
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

-- A short way to name a live note: "#7" when no other live note on the board
-- has counter 7, otherwise its full id.
function Store.noteRef(board, note)
	local n = counter(note.id)
	for _, other in pairs(board.notes or {}) do
		if other ~= note and not other.deleted and counter(other.id) == n then
			return note.id
		end
	end
	return "#" .. n
end

-- Finds a live note by full id, or by counter ("7" or "#7") when that's
-- unique among live notes. Returns the note, or nil and "missing",
-- "deleted" or "ambiguous".
function Store.findNote(board, ref)
	local notes = board.notes or {}
	local exact = notes[ref]
	if exact then
		if exact.deleted then
			return nil, "deleted"
		end
		return exact
	end
	local n = tonumber(match(ref, "^#?(%d+)$"))
	local found
	for _, note in pairs(notes) do
		if n and not note.deleted and counter(note.id) == n then
			if found then
				return nil, "ambiguous"
			end
			found = note
		end
	end
	if not found then
		return nil, "missing"
	end
	return found
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

-- Sharing and members (§4.1, §9, §10) -------------------------------------------

function Store.invite(board)
	return Invite.encode(board)
end

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
		board = {
			id = invite.id,
			secret = invite.secret,
			owner = invite.owner,
			created = now,
			clock = 0,
			notes = {},
			members = {},
			sync = {},
			cloud = true,
			guild = false,
		}
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

-- Cloud sync and the GUILD transport, per board (§4.1).
function Store:setOption(boardId, option, value)
	local board, reason = self:board(boardId)
	if not board then
		return nil, reason
	end
	if option ~= "cloud" and option ~= "guild" then
		return nil, "option"
	end
	board[option] = value and true or false
	self:notify(boardId, "board")
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
