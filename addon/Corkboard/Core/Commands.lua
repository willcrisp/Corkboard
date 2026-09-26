-- The /cork slash commands for sharing and sync options (docs/design.md §9).
-- Boards and notes are edited in the window. Pure Lua 5.1. Commands.run
-- returns the lines to print; the caller puts the gold "Corkboard:" prefix on
-- the first one.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Store = ns.Store or require("Core.Store")
local Invite = ns.Invite or require("Core.Invite")

local format, lower, match = string.format, string.lower, string.match
local floor = math.floor

local Commands = {}

local GREY = "|cff808080"
local YELLOW = "|cffffff00" -- warnings, per docs/ui-style.md

local USAGE = {
	"Commands:",
	"  /cork - open or close the board window",
	"  /cork invite - show the current board's invite string",
	"  /cork join <invite> - join a board from an invite string",
	"  /cork members - list the current board's members",
	"  /cork remove <name> - remove a member (owner only; rotates the secret)",
	"  /cork rotate - give the current board a new secret (owner only)",
	"  /cork cloud on|off, /cork guild on|off - the current board's sync options",
	"  /cork sync - ask members for changes now; /cork debug - the sync panel",
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

-- "now", "5m", "2h", "3d".
function Commands.shortAge(seconds)
	if seconds < 60 then
		return "now"
	elseif seconds < 3600 then
		return floor(seconds / 60) .. "m"
	elseif seconds < 86400 then
		return floor(seconds / 3600) .. "h"
	end
	return floor(seconds / 86400) .. "d"
end

-- "just now", "5m ago", ...
function Commands.age(seconds)
	return seconds < 60 and "just now" or Commands.shortAge(seconds) .. " ago"
end

-- "1 note", "3 notes".
function Commands.plural(n, word)
	return n .. " " .. word .. (n == 1 and "" or "s")
end

local plural = Commands.plural

local function current(store)
	local board = store:current()
	if not board then
		return nil, { warn("No board selected. Open /cork to create or pick one.") }
	end
	return board
end

local handlers = {}

function handlers.help()
	return USAGE
end

function handlers.invite(store)
	local board, problem = current(store)
	if not board then
		return problem
	end
	return {
		format("Invite for %s. Anyone with it can read and edit the board:", Store.name(board)),
		Invite.encode(board),
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

local ALIASES = { ["?"] = "help", [""] = "help" }

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
