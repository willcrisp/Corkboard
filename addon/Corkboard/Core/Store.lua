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
	return setmetatable({ db = db, env = env }, Store)
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
	return Merge.setMeta(board, name, editor, self.env.now())
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

function Store:addNote(boardId, text, color)
	local board, author = noteChange(self, boardId)
	if not board then
		return nil, author
	end
	local id, reason = Store.nextNoteId(board, self.env.prefix)
	if not id then
		return nil, reason
	end
	return Merge.createNote(board, { id = id, author = author, text = text, color = color }, self.env.now())
end

-- changes: text and/or color.
function Store:editNote(boardId, noteId, changes)
	local board, editor = noteChange(self, boardId)
	if not board then
		return nil, editor
	end
	return Merge.editNote(board, noteId, changes, editor, self.env.now())
end

function Store:deleteNote(boardId, noteId)
	local board, editor = noteChange(self, boardId)
	if not board then
		return nil, editor
	end
	return Merge.deleteNote(board, noteId, editor, self.env.now())
end

ns.Store = Store
return Store
