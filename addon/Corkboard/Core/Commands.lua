-- The /cork slash commands: a minimal text interface to the store until the
-- UI exists (docs/design.md §9). Pure Lua 5.1. Commands.run returns the lines
-- to print; the caller puts the gold "Corkboard:" prefix on the first one.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Store = ns.Store or require("Core.Store")

local format, lower, match = string.format, string.lower, string.match
local floor = math.floor

local Commands = {}

Commands.MAX_COLOR = 5 -- the UI's colours; the sanitiser allows up to 8

local GREY = "|cff808080"
local YELLOW = "|cffffff00" -- warnings, per docs/ui-style.md

local USAGE = {
	"Commands:",
	"  /cork - open or close the board window",
	"  /cork boards - list your boards",
	"  /cork create <name> - create a board and switch to it",
	"  /cork use <board> - switch boards (name or id)",
	"  /cork rename <name> - rename the current board",
	"  /cork deleteboard <board> - delete a board from this account",
	"  /cork list - list the current board's notes",
	"  /cork add <text> - add a note (shift-click links in)",
	"  /cork edit <note> <text> - replace a note's text",
	"  /cork color <note> <1-" .. Commands.MAX_COLOR .. "> - change a note's colour",
	"  /cork delete <note> - delete a note",
	"  /cork invite - show the current board's invite string",
	"  /cork join <invite> - join a board from an invite string",
	"  /cork members - list the current board's members",
	"  /cork remove <name> - remove a member (owner only; rotates the secret)",
	"  /cork rotate - give the current board a new secret (owner only)",
	"  /cork cloud on|off, /cork guild on|off - the current board's sync options",
	"  /cork sync - ask members for changes now; /cork debug - the sync panel",
	"A <note> is its #number from /cork list, or its full id.",
}

local REASONS = {
	identity = "Your character isn't known yet. Try again in a moment.",
	author = "Your character name couldn't be read.",
	editor = "Your character name couldn't be read.",
	name = format("Board names are 1-%d bytes, with no | or line breaks.", Sanitise.MAX_BOARD_NAME),
	too_long = format("Notes are limited to %d bytes.", Sanitise.MAX_TEXT),
	utf8 = "That text isn't valid UTF-8.",
	control = "Notes can't contain control characters other than line breaks.",
	escape = "Notes can hold links and colours, but not textures, icons or other escape codes.",
	link = "That link is malformed.",
	link_type = "That kind of link can't go on a board. Items, quests, spells, achievements, currencies, "
		.. "mounts, battle pets and journal links can.",
	color = format("Colours are 1-%d.", Commands.MAX_COLOR),
	id_space = "You've run out of note ids on this board.",
	deleted = "That note has been deleted.",
	missing = "That board or note no longer exists.",
	invite = "That isn't a Corkboard invite. It starts with CORK1:",
	invite_version = "That invite is from a newer version of Corkboard. Update the addon to join.",
	invite_corrupt = "That invite is damaged. Copy the whole string again.",
	not_owner = "Only the board's owner can do that.",
	not_member = "They aren't a member of this board.",
	remove_self = "You can't remove yourself. Delete the board from this account instead.",
	option = "Unknown option.",
}

local function warn(text)
	return YELLOW .. text .. "|r"
end

-- A sentence for a store or sanitiser reason code. The note editor uses it too.
function Commands.explain(reason)
	return REASONS[reason] or ("That didn't work (" .. tostring(reason) .. ").")
end

local function failure(reason)
	return { warn(Commands.explain(reason)) }
end

function Commands.age(seconds)
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return floor(seconds / 60) .. "m ago"
	elseif seconds < 86400 then
		return floor(seconds / 3600) .. "h ago"
	end
	return floor(seconds / 86400) .. "d ago"
end

local function countNotes(board)
	return #Store.notes(board)
end

local function plural(n, word)
	return n .. " " .. word .. (n == 1 and "" or "s")
end

local function current(store)
	local board = store:current()
	if not board then
		return nil, { warn("No board selected. Use /cork create <name> or /cork use <board>.") }
	end
	return board
end

local function findBoard(store, query)
	local board, reason = store:findBoard(query)
	if not board then
		if reason == "ambiguous" then
			return nil, { warn(format("More than one board matches %q. Use its id from /cork boards.", query)) }
		end
		return nil, { warn(format("No board matches %q.", query)) }
	end
	return board
end

local function findNote(board, ref)
	local note, reason = Store.findNote(board, ref)
	if not note then
		if reason == "ambiguous" then
			return nil, { warn(format("More than one note is #%s. Use its full id from /cork list.", match(ref, "%d+"))) }
		elseif reason == "deleted" then
			return nil, failure("deleted")
		end
		return nil, { warn(format("No note %q on this board.", ref)) }
	end
	return note
end

local handlers = {}

function handlers.help()
	return USAGE
end

function handlers.boards(store)
	local boards = store:boards()
	if #boards == 0 then
		return { "No boards yet. Use /cork create <name>." }
	end
	local out = { "Boards:" }
	local selected = store:current()
	for _, board in ipairs(boards) do
		out[#out + 1] = format(
			"  %s%s %s- %s, id %s|r",
			Store.name(board),
			board == selected and " (current)" or "",
			GREY,
			plural(countNotes(board), "note"),
			board.id
		)
	end
	return out
end

function handlers.create(store, name)
	if name == "" then
		return { "Usage: /cork create <name>" }
	end
	local board, reason = store:createBoard(name)
	if not board then
		return failure(reason)
	end
	return { format("Created board %s (id %s). It's now the current board.", Store.name(board), board.id) }
end

function handlers.use(store, query)
	if query == "" then
		return { "Usage: /cork use <board>" }
	end
	local board, problem = findBoard(store, query)
	if not board then
		return problem
	end
	store:select(board.id)
	return { format("Now using %s.", Store.name(board)) }
end

function handlers.rename(store, name)
	if name == "" then
		return { "Usage: /cork rename <name>" }
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local old = Store.name(board)
	local meta, reason = store:renameBoard(board.id, name)
	if not meta then
		return failure(reason)
	end
	return { format("Renamed %s to %s.", old, meta.name) }
end

function handlers.deleteboard(store, query)
	if query == "" then
		return { "Usage: /cork deleteboard <board> (name or id; there's no undo)" }
	end
	local board, problem = findBoard(store, query)
	if not board then
		return problem
	end
	store:deleteBoard(board.id)
	return {
		format("Deleted %s from this account (%s).", Store.name(board), plural(countNotes(board), "note")),
		"Other members keep their copies.",
	}
end

function handlers.list(store)
	local board, problem = current(store)
	if not board then
		return problem
	end
	local notes = Store.notes(board)
	local out = { format("%s: %s", Store.name(board), plural(#notes, "note")) }
	local now = store.env.now()
	for _, note in ipairs(notes) do
		out[#out + 1] = format(
			"  %s %s %s(%s, %s%s)|r",
			Store.noteRef(board, note),
			note.text,
			GREY,
			note.author,
			Commands.age(now - note.rev),
			note.color ~= 1 and ", colour " .. note.color or ""
		)
	end
	return out
end

function handlers.add(store, text)
	if text == "" then
		return { "Usage: /cork add <text>" }
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local note, reason = store:addNote(board.id, text)
	if not note then
		return failure(reason)
	end
	return { format("Added %s to %s.", Store.noteRef(board, note), Store.name(board)) }
end

function handlers.edit(store, rest)
	local ref, text = match(rest, "^(%S+)%s+(.+)$")
	if not ref then
		return { "Usage: /cork edit <note> <text>" }
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local note
	note, problem = findNote(board, ref)
	if not note then
		return problem
	end
	local edited, reason = store:editNote(board.id, note.id, { text = text })
	if not edited then
		return failure(reason)
	end
	return { format("Edited %s.", Store.noteRef(board, edited)) }
end

function handlers.color(store, rest)
	local ref, color = match(rest, "^(%S+)%s+(%d+)$")
	color = tonumber(color)
	if not ref then
		return { format("Usage: /cork color <note> <1-%d>", Commands.MAX_COLOR) }
	end
	if color < 1 or color > Commands.MAX_COLOR then
		return failure("color")
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local note
	note, problem = findNote(board, ref)
	if not note then
		return problem
	end
	local edited, reason = store:editNote(board.id, note.id, { color = color })
	if not edited then
		return failure(reason)
	end
	return { format("%s is now colour %d.", Store.noteRef(board, edited), color) }
end

function handlers.delete(store, ref)
	if ref == "" then
		return { "Usage: /cork delete <note>" }
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local note
	note, problem = findNote(board, ref)
	if not note then
		return problem
	end
	local label = Store.noteRef(board, note)
	local deleted, reason = store:deleteNote(board.id, note.id)
	if not deleted then
		return failure(reason)
	end
	return { format("Deleted %s from %s.", label, Store.name(board)) }
end

function handlers.invite(store)
	local board, problem = current(store)
	if not board then
		return problem
	end
	return {
		format("Invite for %s. Anyone with it can read and edit the board:", Store.name(board)),
		Store.invite(board),
		GREY .. "Addons can't copy to the clipboard: open the Members tab in /cork to copy it.|r",
	}
end

function handlers.join(store, text)
	if text == "" then
		return { "Usage: /cork join <invite>" }
	end
	local board, new = store:joinBoard(text)
	if not board then
		return failure(new)
	end
	if not new then
		return { format("You're already on %s. Its invite is up to date.", Store.name(board)) }
	end
	return { format("Joined %s. Its notes arrive when another member is online.", Store.name(board)) }
end

function handlers.members(store)
	local board, problem = current(store)
	if not board then
		return problem
	end
	local members = Store.members(board)
	local out = { format("%s: %s", Store.name(board), plural(#members, "member")) }
	local now = store.env.now()
	for _, m in ipairs(members) do
		local seen = board.seen and board.seen[m.name]
		out[#out + 1] = format("  %s %s(%s%s)|r", m.name, GREY, m.role,
			seen and ", seen " .. Commands.age(now - seen.at) or "")
	end
	return out
end

function handlers.remove(store, name)
	if name == "" then
		return { "Usage: /cork remove <Name-Realm>" }
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local record, reason = store:removeMember(board.id, name)
	if not record then
		return failure(reason)
	end
	return {
		format("Removed %s from %s and changed its secret.", name, Store.name(board)),
		"Everyone you keep needs the new invite: /cork invite.",
	}
end

function handlers.rotate(store)
	local board, problem = current(store)
	if not board then
		return problem
	end
	local ok, reason = store:rotateSecret(board.id)
	if not ok then
		return failure(reason)
	end
	return { format("%s has a new secret. Every member needs the new invite: /cork invite.", Store.name(board)) }
end

local function option(name, label)
	return function(store, value)
		value = lower(value)
		if value ~= "on" and value ~= "off" then
			return { format("Usage: /cork %s on|off", name) }
		end
		local board, problem = current(store)
		if not board then
			return problem
		end
		store:setOption(board.id, name, value == "on")
		return { format("%s for %s is %s.", label, Store.name(board), value) }
	end
end

handlers.cloud = option("cloud", "Cloud sync")
handlers.guild = option("guild", "Guild sync")

local ALIASES = { new = "create", del = "delete", colour = "color", ["?"] = "help", [""] = "help" }

-- Runs one /cork command line. Returns the lines to print.
function Commands.run(store, input)
	local word, rest = match(input or "", "^%s*(%S*)%s*(.-)%s*$")
	word = lower(word)
	local handler = handlers[ALIASES[word] or word]
	if not handler then
		local out = { warn(format("Unknown command %q.", word)) }
		for _, line in ipairs(USAGE) do
			out[#out + 1] = line
		end
		return out
	end
	return handler(store, rest)
end

ns.Commands = Commands
return Commands
