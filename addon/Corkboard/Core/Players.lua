-- Player notes for the Players tab (docs/design.md §9.4): a board's shared
-- avoid list and good-player list. Each entry is a Note with kind = "player",
-- whose text is a header line and then the reason, free text that may hold
-- links like any note:
--
--   P1;<verdict>;<character name>
--   <why>
--
-- The verdict is "avoid" or "good". Pure Lua 5.1: the tab's rows, the chat
-- lookup and the unit tooltip lines are all built from what's here.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Merge = ns.Merge or require("Core.Merge")

local find, format, gsub, lower, match, sub = string.find, string.format, string.gsub, string.lower, string.match,
	string.sub
local sort = table.sort

local Players = {}

Players.KIND = "player"
Players.MAX_NAME = 64 -- bytes of character name
Players.VERDICTS = { avoid = true, good = true }
Players.LABELS = { avoid = "Avoid", good = "Good player" }

local HEADER = "^P1;(%l+);([^;\n]+)$"

-- A character name as typed, tidied: spaces trimmed and runs of spaces made
-- one. Returns it, or nil and "player_name" when it can't go in a header:
-- 1-64 bytes of UTF-8 with a letter or digit in the first word, and no ";",
-- "|" or control characters. "Name", "Name-Realm" and Forever's
-- "Name Surname" all pass.
function Players.cleanName(name)
	if type(name) ~= "string" then
		return nil, "player_name"
	end
	name = gsub(gsub(gsub(name, "^%s+", ""), "%s+$", ""), "%s+", " ")
	if #name < 1 or #name > Players.MAX_NAME or find(name, "[;|%c]") or not Util.isUtf8(name)
		or not Players.key(name) then
		return nil, "player_name"
	end
	return name
end

-- What entries are matched on: the first word of the name, before any
-- surname or realm, ASCII lower-cased. Forever names can carry a surname
-- ("Aprune Proudshield-Realm"), and units, chat and typed names don't agree
-- on whether it's there, so the first name is the part every form shares.
-- Two characters on different realms can share it; the tooltip and chat
-- show the name as written so the reader can tell.
function Players.key(name)
	local first = type(name) == "string" and match(name, "^%s*([^%s%-]+)")
	if not first or not find(first, "[%w\128-\255]") then
		return nil
	end
	return lower(first)
end

-- The note text for an entry. Returns it, or nil and a reason: "player_name",
-- "verdict", or a sanitiser reason for the text as a whole ("too_long",
-- "escape", "link_type" and so on).
function Players.encode(name, verdict, reason)
	local clean, why = Players.cleanName(name)
	if not clean then
		return nil, why
	end
	if not Players.VERDICTS[verdict] then
		return nil, "verdict"
	end
	reason = gsub(gsub(type(reason) == "string" and reason or "", "^%s+", ""), "%s+$", "")
	local text = format("P1;%s;%s", verdict, clean)
	if reason ~= "" then
		text = text .. "\n" .. reason
	end
	local ok
	ok, why = Sanitise.text(text)
	if not ok then
		return nil, why
	end
	return text
end

-- Reads an entry's text: { name, verdict, reason, key }, or nil when it isn't
-- one this client understands (a malformed entry, or a verdict from a newer
-- client). It still syncs; the tab just leaves it out.
function Players.decode(text)
	if type(text) ~= "string" then
		return nil
	end
	local newline = find(text, "\n", 1, true)
	local header = newline and sub(text, 1, newline - 1) or text
	local verdict, name = match(header, HEADER)
	if not verdict or not Players.VERDICTS[verdict] or Players.cleanName(name) ~= name then
		return nil
	end
	return { name = name, verdict = verdict, reason = newline and sub(text, newline + 1) or "", key = Players.key(name) }
end

-- The board's live entries, by name (case folded), then newest first:
-- { note, name, verdict, reason, key }.
function Players.entries(board)
	local list = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted and note.kind == Players.KIND then
			local entry = Players.decode(note.text)
			if entry then
				entry.note = note
				list[#list + 1] = entry
			end
		end
	end
	sort(list, function(a, b)
		local c = Util.compare(lower(a.name), lower(b.name))
		if c ~= 0 then
			return c < 0
		end
		c = Merge.compareVersion(a.note, b.note)
		if c ~= 0 then
			return c > 0
		end
		return Util.less(a.note.id, b.note.id)
	end)
	return list
end

-- Every entry across `boards` (a list), by Players.key: key -> entries, each
-- also carrying its `board`, avoid entries first, then newest first. The
-- addon keeps one of these for unit tooltips and rebuilds it after any change.
function Players.index(boards)
	local index = {}
	for _, board in ipairs(boards) do
		for _, entry in ipairs(Players.entries(board)) do
			entry.board = board
			local list = index[entry.key] or {}
			index[entry.key] = list
			list[#list + 1] = entry
		end
	end
	local function order(a, b)
		if a.verdict ~= b.verdict then
			return a.verdict == "avoid"
		end
		local c = Merge.compareVersion(a.note, b.note)
		if c ~= 0 then
			return c > 0
		end
		return Util.less(a.note.id, b.note.id)
	end
	for _, list in pairs(index) do
		sort(list, order)
	end
	return index
end

-- Every entry about one character across `boards`, in Players.index's
-- order. `name` is any form of the character's name.
function Players.lookup(boards, name)
	local key = Players.key(name)
	return key and Players.index(boards)[key] or {}
end

ns.Players = Players
return Players
