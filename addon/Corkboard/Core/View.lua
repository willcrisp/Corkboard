-- The logic behind the board window and note editor (docs/design.md §9,
-- docs/ui-style.md): search, layout rows, labels and editor checks. Pure Lua
-- 5.1, so busted tests it; the frames in UI/ only draw what this returns.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Commands = ns.Commands or require("Core.Commands")

local find, format, gsub, lower, match = string.find, string.format, string.gsub, string.lower, string.match
local floor = math.floor

local View = {}

View.COLUMNS = 2

-- Note tags, by note colour 1-5: the muted squares from docs/ui-style.md.
local function rgb(hex)
	return {
		tonumber(hex:sub(1, 2), 16) / 255,
		tonumber(hex:sub(3, 4), 16) / 255,
		tonumber(hex:sub(5, 6), 16) / 255,
	}
end

View.TAGS = {
	{ name = "Amber", color = rgb("9a7a3c") },
	{ name = "Blue", color = rgb("4f6f92") },
	{ name = "Green", color = rgb("5d7d4c") },
	{ name = "Rose", color = rgb("8f5563") },
	{ name = "Violet", color = rgb("6d5c8f") },
}

-- The tag for a note colour. Colours 6-8 pass the sanitiser (a newer client
-- may use them) but have no tag yet, so they show as the first one.
function View.tag(color)
	return View.TAGS[color] or View.TAGS[1]
end

-- "now", "5m", "2h", "3d": the card corner (docs/mockups/Main).
function View.shortAge(seconds)
	if seconds < 60 then
		return "now"
	elseif seconds < 3600 then
		return floor(seconds / 60) .. "m"
	elseif seconds < 86400 then
		return floor(seconds / 3600) .. "h"
	end
	return floor(seconds / 86400) .. "d"
end

-- A character name without the realm when it's the player's own realm.
function View.shortName(name, myRealm)
	local short, realm = match(name, "^([^%-]+)%-(.+)$")
	if short and realm == myRealm then
		return short
	end
	return name
end

function View.realmOf(name)
	return name and match(name, "^[^%-]+%-(.+)$")
end

-- Note text as a reader sees it: links become their [display text], and
-- colour and escape codes go. Only applied to text that passed the sanitiser.
function View.plainText(text)
	text = gsub(text, "|H[^|]*|h([^|]*)|h", "%1")
	text = gsub(text, "|c%x%x%x%x%x%x%x%x", "")
	text = gsub(text, "|cn[%w_]+:", "")
	text = gsub(text, "|r", "")
	return (gsub(text, "||", "|"))
end

-- Search: every word of the query must appear (ASCII case folded) in the
-- note's plain text or its author's or editor's name.
function View.matches(note, query)
	local haystack = lower(View.plainText(note.text) .. "\n" .. note.author .. "\n" .. note.editor)
	for word in string.gmatch(lower(query or ""), "%S+") do
		if not find(haystack, word, 1, true) then
			return false
		end
	end
	return true
end

function View.filter(notes, query)
	local out = {}
	for _, note in ipairs(notes) do
		if View.matches(note, query) then
			out[#out + 1] = note
		end
	end
	return out
end

-- Groups notes into rows of View.COLUMNS for the card grid.
function View.rows(notes)
	local rows = {}
	for i, note in ipairs(notes) do
		local r = floor((i - 1) / View.COLUMNS) + 1
		rows[r] = rows[r] or {}
		rows[r][#rows[r] + 1] = note
	end
	return rows
end

-- "Will" or "Kaelthra · edited by Mira".
function View.byline(note, myRealm)
	local author = View.shortName(note.author, myRealm)
	if note.editor == note.author then
		return author
	end
	return format("%s · edited by %s", author, View.shortName(note.editor, myRealm))
end

-- The editor's header: "Molten Core prep · created by Will 2h ago · edited by Bob 14m ago".
function View.editorHeader(boardName, note, now, myRealm)
	if not note then
		return boardName .. " · new note"
	end
	local parts = {
		boardName,
		format("created by %s %s", View.shortName(note.author, myRealm), Commands.age(now - note.created)),
	}
	if note.rev ~= note.created or note.editor ~= note.author then
		parts[3] = format("edited by %s %s", View.shortName(note.editor, myRealm), Commands.age(now - note.rev))
	end
	return table.concat(parts, " · ")
end

-- The byte counter under the editor, and whether the text is over the limit.
function View.counter(text)
	return format("%d / %d", #text, Sanitise.MAX_TEXT), #text > Sanitise.MAX_TEXT
end

-- Whether the editor may save this text. Returns true, or false and the
-- message to show. Text a peer's sanitiser would reject can't be saved.
function View.check(text)
	if not find(text, "%S") then
		return false, "Write something first."
	end
	local ok, reason = Sanitise.text(text)
	if not ok then
		return false, Commands.explain(reason)
	end
	return true
end

-- What an editor save changes, or nil when nothing did. Saving an unchanged
-- note would bump its rev and send it to every member for nothing.
function View.changes(note, text, color)
	local changes = {}
	if text ~= note.text then
		changes.text = text
	end
	if color ~= note.color then
		changes.color = color
	end
	if next(changes) == nil then
		return nil
	end
	return changes
end

-- The status line: sync comes in Phase 2, so for now every board is local.
function View.status(noteCount, shownCount)
	local count = noteCount == shownCount and format("%d notes", noteCount)
		or format("%d of %d notes", shownCount, noteCount)
	if noteCount == 1 and shownCount == 1 then
		count = "1 note"
	end
	return "Local only: sync arrives with invites", count
end

-- The line under a board's name in the board list.
function View.boardDetail(noteCount)
	return noteCount == 1 and "1 note" or format("%d notes", noteCount)
end

ns.View = View
return View
