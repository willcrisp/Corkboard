-- Merge rules (docs/design.md §4.3): last-writer-wins on (rev, editor),
-- tombstones for deletes, and the HLC-lite board clock. Pure Lua 5.1.
--
-- A board here is any table with `clock`, `notes` (id -> Note) and `members`
-- (name -> MemberRecord). Missing fields are created on first write.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Sanitise = ns.Sanitise or require("Core.Sanitise")

local compareBytes = Util.compare

local Merge = {}

local function compareNumber(x, y)
	if x == y then
		return 0
	end
	return x < y and -1 or 1
end

-- true sorts above false.
local function compareBool(x, y)
	if x == y then
		return 0
	end
	return x and 1 or -1
end

-- The version order: rev, then editor byte by byte.
function Merge.compareVersion(a, b)
	local c = compareNumber(a.rev, b.rev)
	if c ~= 0 then
		return c
	end
	return compareBytes(a.editor, b.editor)
end

-- Total order on two notes with the same id. Content only matters on an exact
-- (rev, editor) tie, which honest clients produce only when one character
-- edits on two installs. A tombstone wins the tie, then the greater text,
-- color, author and created. Taking the maximum of a total order is what makes
-- merging commutative, associative and idempotent.
function Merge.compareNote(a, b)
	local c = Merge.compareVersion(a, b)
	if c ~= 0 then
		return c
	end
	c = compareBool(a.deleted, b.deleted)
	if c ~= 0 then
		return c
	end
	c = compareBytes(a.text, b.text)
	if c ~= 0 then
		return c
	end
	c = compareNumber(a.color, b.color)
	if c ~= 0 then
		return c
	end
	c = compareBytes(a.author, b.author)
	if c ~= 0 then
		return c
	end
	return compareNumber(a.created, b.created)
end

-- Same idea for MemberRecords: a removal wins the tie, then the greater role.
function Merge.compareMember(a, b)
	local c = Merge.compareVersion(a, b)
	if c ~= 0 then
		return c
	end
	c = compareBool(a.removed, b.removed)
	if c ~= 0 then
		return c
	end
	return compareBytes(a.role, b.role)
end

-- Clock -------------------------------------------------------------------

-- On receiving a record: clock = max(clock, rev).
function Merge.observe(board, rev)
	if rev > (board.clock or 0) then
		board.clock = rev
	end
end

-- The rev for the next local change: max(now, clock + 1). `now` is
-- GetServerTime() in game. This doesn't advance the clock; committing does.
function Merge.nextRev(board, now)
	local after = (board.clock or 0) + 1
	return now > after and now or after
end

-- Received records --------------------------------------------------------

local function records(board, field)
	local t = board[field]
	if not t then
		t = {}
		board[field] = t
	end
	return t
end

local function store(board, field, key, clean, compare)
	Merge.observe(board, clean.rev)
	local t = records(board, field)
	local current = t[key]
	if current and compare(clean, current) <= 0 then
		return false, "stale"
	end
	t[key] = clean
	return true
end

-- Merges one received note. Returns true if it was stored, or false and a
-- reason: "stale" when the board already holds an equal or newer version,
-- otherwise the sanitiser's reason for dropping it. The board keeps a clean
-- copy, never the caller's table.
function Merge.applyNote(board, note)
	local clean, reason = Sanitise.note(note)
	if not clean then
		return false, reason
	end
	return store(board, "notes", clean.id, clean, Merge.compareNote)
end

function Merge.applyMember(board, member)
	local clean, reason = Sanitise.member(member)
	if not clean then
		return false, reason
	end
	return store(board, "members", clean.name, clean, Merge.compareMember)
end

local function applyAll(board, list, apply, key)
	local stored, dropped = {}, {}
	for _, record in pairs(list) do
		local ok, reason = apply(board, record)
		if ok then
			stored[#stored + 1] = record[key]
		elseif reason ~= "stale" then
			dropped[#dropped + 1] = reason
		end
	end
	return stored, dropped
end

-- Merges a list (or map) of notes, in any order. Returns the ids stored and
-- the reasons for any records dropped.
function Merge.applyNotes(board, notes)
	return applyAll(board, notes, Merge.applyNote, "id")
end

function Merge.applyMembers(board, members)
	return applyAll(board, members, Merge.applyMember, "name")
end

-- Local changes -------------------------------------------------------------
-- Each returns the new record, or nil and a reason. A change that the
-- sanitiser would reject on a peer is refused here too, and leaves the board
-- (including its clock) untouched.

local function commit(board, field, key, record, sanitise)
	local clean, reason = sanitise(record)
	if not clean then
		return nil, reason
	end
	Merge.observe(board, clean.rev)
	records(board, field)[clean[key]] = clean
	return clean
end

-- fields: id, author, text, color (default 1).
function Merge.createNote(board, fields, now)
	if board.notes and board.notes[fields.id] then
		return nil, "exists"
	end
	return commit(board, "notes", "id", {
		id = fields.id,
		author = fields.author,
		created = now,
		rev = Merge.nextRev(board, now),
		editor = fields.author,
		text = fields.text,
		color = fields.color or 1,
		deleted = false,
	}, Sanitise.note)
end

local function current(board, id)
	local note = board.notes and board.notes[id]
	if not note then
		return nil, "missing"
	end
	if note.deleted then
		return nil, "deleted"
	end
	return note
end

-- changes: text and/or color; anything left nil keeps its current value.
function Merge.editNote(board, id, changes, editor, now)
	local note, reason = current(board, id)
	if not note then
		return nil, reason
	end
	local text, color = changes.text, changes.color
	if text == nil then
		text = note.text
	end
	if color == nil then
		color = note.color
	end
	return commit(board, "notes", "id", {
		id = id,
		author = note.author,
		created = note.created,
		rev = Merge.nextRev(board, now),
		editor = editor,
		text = text,
		color = color,
		deleted = false,
	}, Sanitise.note)
end

-- A delete is an edit that leaves a tombstone: deleted = true, text = "".
function Merge.deleteNote(board, id, editor, now)
	local note, reason = current(board, id)
	if not note then
		return nil, reason
	end
	return commit(board, "notes", "id", {
		id = id,
		author = note.author,
		created = note.created,
		rev = Merge.nextRev(board, now),
		editor = editor,
		text = "",
		color = note.color,
		deleted = true,
	}, Sanitise.note)
end

-- Adds, changes or removes (removed = true) a member.
function Merge.setMember(board, name, role, removed, editor, now)
	return commit(board, "members", "name", {
		name = name,
		role = role,
		rev = Merge.nextRev(board, now),
		editor = editor,
		removed = removed,
	}, Sanitise.member)
end

ns.Merge = Merge
return Merge
