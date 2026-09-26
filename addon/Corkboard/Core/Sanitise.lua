-- Sanitiser (docs/design.md §6). Every received note and member record goes
-- through here before it reaches the store. It is a predicate, not a repair:
-- a record either passes unchanged or is dropped, so every client that accepts
-- a given (rev, editor) holds the same bytes. Python must match it exactly;
-- shared/test-vectors/sanitise.json pins the behaviour and the reason codes.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")

local find, sub = string.find, string.sub

local Sanitise = {}

Sanitise.MAX_TEXT = 2000 -- bytes per note
Sanitise.MAX_NAME = 64 -- bytes per "Name-Realm"
Sanitise.MAX_BOARD_NAME = 64 -- bytes per board name
Sanitise.MAX_ID = 18 -- "a1b2c3d4-" plus up to 9 digits
Sanitise.COLOR_MAX = 8 -- the UI uses 1-5; 6-8 are reserved

Sanitise.LINK_TYPES = {
	item = true,
	quest = true,
	spell = true,
	achievement = true,
	currency = true,
	mount = true,
	battlepet = true,
	journal = true,
}

-- Note kinds (§4.2). A note without `kind` is an ordinary note; "gear" is an
-- entry in the board's gear feed (§9.1).
Sanitise.KINDS = {
	gear = true,
}

local LINK_TYPES = Sanitise.LINK_TYPES
local INT_MAX = Util.INT_MAX

-- C0 controls and DEL; note text may also hold "\n". %z is "\0" in Lua 5.1 patterns.
local CONTROL = "[%z\1-\31\127]"
local TEXT_CONTROL = "[%z\1-\9\11-\31\127]"
local HEX8 = "^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]"
local NOTE_ID = "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9]+$"

-- Walks the UI escape sequences left to right. Allowed:
--   ||                         literal pipe
--   |cAARRGGBB  |cnNAME:  |r   colours (hex and named)
--   |H<type>:<data>|h<text>|h  hyperlink with an allowed type; no "|" inside
-- Anything else after a "|" (textures |T, atlases |A, |K tokens, |n, ...) fails.
local function checkEscapes(s)
	local pos = 1
	while true do
		local p = find(s, "|", pos, true)
		if not p then
			return true
		end
		local c = sub(s, p + 1, p + 1)
		if c == "|" or c == "r" then
			pos = p + 2
		elseif c == "c" then
			if find(s, HEX8, p + 2) then
				pos = p + 10
			else
				local _, e = find(s, "^n[0-9A-Za-z_]+:", p + 2)
				if not e then
					return false, "escape"
				end
				pos = e + 1
			end
		elseif c == "H" then
			local _, e, linkType = find(s, "^([^:|]*):", p + 2)
			if not e then
				return false, "link"
			end
			if not LINK_TYPES[linkType] then
				return false, "link_type"
			end
			local _, e2 = find(s, "^[^|]*|h[^|]*|h", e + 1)
			if not e2 then
				return false, "link"
			end
			pos = e2 + 1
		else
			return false, "escape"
		end
	end
end

-- Note text. Returns true, or false and a reason. Checks run in this order,
-- and the first failure is the reason: text, too_long, utf8, control, then the
-- escape scan (escape, link, link_type) left to right.
function Sanitise.text(s)
	if type(s) ~= "string" then
		return false, "text"
	end
	if #s > Sanitise.MAX_TEXT then
		return false, "too_long"
	end
	if not Util.isUtf8(s) then
		return false, "utf8"
	end
	if find(s, TEXT_CONTROL) then
		return false, "control"
	end
	return checkEscapes(s)
end

-- A character name, "Name-Realm". No controls at all: a newline in an editor
-- would forge a line in the digest.
function Sanitise.name(s)
	return type(s) == "string"
		and #s <= Sanitise.MAX_NAME
		and find(s, "^[^%-]+%-.") ~= nil
		and not find(s, "|", 1, true)
		and not find(s, CONTROL)
		and Util.isUtf8(s)
end

-- A board name: 1-64 bytes of strict UTF-8 with at least one non-space, and
-- no controls or "|". It's plain text everywhere it's shown.
function Sanitise.boardName(s)
	return type(s) == "string"
		and #s <= Sanitise.MAX_BOARD_NAME
		and find(s, "%S") ~= nil
		and not find(s, "|", 1, true)
		and not find(s, CONTROL)
		and Util.isUtf8(s)
end

-- A note id: "<8 lower-case hex>-<digits>", at most 18 bytes (§4.2).
function Sanitise.noteId(id)
	return type(id) == "string" and #id <= Sanitise.MAX_ID and find(id, NOTE_ID) ~= nil
end

-- Returns a clean copy holding only the known fields, or nil and a reason.
-- Unknown fields are ignored so a newer client's notes still load here.
function Sanitise.note(t)
	if type(t) ~= "table" then
		return nil, "type"
	end
	local id = t.id
	if not Sanitise.noteId(id) then
		return nil, "id"
	end
	if not Sanitise.name(t.author) then
		return nil, "author"
	end
	if not Util.isInteger(t.created, 0, INT_MAX) then
		return nil, "created"
	end
	if not Util.isInteger(t.rev, 1, INT_MAX) then
		return nil, "rev"
	end
	if not Sanitise.name(t.editor) then
		return nil, "editor"
	end
	if not Util.isInteger(t.color, 1, Sanitise.COLOR_MAX) then
		return nil, "color"
	end
	if type(t.deleted) ~= "boolean" then
		return nil, "deleted"
	end
	if t.kind ~= nil and not (type(t.kind) == "string" and Sanitise.KINDS[t.kind]) then
		return nil, "kind"
	end
	local ok, reason = Sanitise.text(t.text)
	if not ok then
		return nil, reason
	end
	if t.deleted and t.text ~= "" then
		return nil, "tombstone_text"
	end
	return {
		id = id,
		author = t.author,
		created = t.created,
		rev = t.rev,
		editor = t.editor,
		text = t.text,
		color = t.color,
		deleted = t.deleted,
		kind = t.kind,
	}
end

-- MemberRecord (§4.2). Same contract as Sanitise.note.
function Sanitise.member(t)
	if type(t) ~= "table" then
		return nil, "type"
	end
	if not Sanitise.name(t.name) then
		return nil, "name"
	end
	if t.role ~= "owner" and t.role ~= "member" then
		return nil, "role"
	end
	if not Util.isInteger(t.rev, 1, INT_MAX) then
		return nil, "rev"
	end
	if not Sanitise.name(t.editor) then
		return nil, "editor"
	end
	if type(t.removed) ~= "boolean" then
		return nil, "removed"
	end
	return {
		name = t.name,
		role = t.role,
		rev = t.rev,
		editor = t.editor,
		removed = t.removed,
	}
end

-- BoardMeta (§4.1): the board's replicated name. Same contract as Sanitise.note.
function Sanitise.meta(t)
	if type(t) ~= "table" then
		return nil, "type"
	end
	if not Sanitise.boardName(t.name) then
		return nil, "name"
	end
	if not Util.isInteger(t.rev, 1, INT_MAX) then
		return nil, "rev"
	end
	if not Sanitise.name(t.editor) then
		return nil, "editor"
	end
	return {
		name = t.name,
		rev = t.rev,
		editor = t.editor,
	}
end

ns.Sanitise = Sanitise
return Sanitise
