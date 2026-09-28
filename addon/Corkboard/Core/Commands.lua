-- The /cork slash commands for sharing and sync options (docs/design.md §9).
-- Boards and notes are edited in the window. Pure Lua 5.1. Commands.run
-- returns the lines to print; the caller puts the gold "Corkboard:" prefix on
-- the first one.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Store = ns.Store or require("Core.Store")
local Invite = ns.Invite or require("Core.Invite")
local Util = ns.Util or require("Core.Util")
local Players = ns.Players or require("Core.Players")

local format, gsub, lower, match, sub = string.format, string.gsub, string.lower, string.match, string.sub
local floor = math.floor
local concat, sort = table.concat, table.sort

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
	"  /cork quests [name] - who shares a quest log here, or one member's quests",
	"  /cork quests on|off - share your quest log with the current board",
	"  /cork player <name> - what your boards say about a player",
	"  /cork sync - ask members for changes now; /cork debug - the sync panel",
	"  /cork minimap - show or hide the minimap button",
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
		.. "mounts, battle pets, journal, recipe and profession links can.",
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
	player_name = format("Character names are 1-%d bytes, with no ; or | in them.", Players.MAX_NAME),
	verdict = "Pick Avoid or Good player.",
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

Commands.RECENT_DONE = 3 -- turn-ins /cork quests <name> lists

-- Quest logs (§9.3) -----------------------------------------------------------

-- The mark on a quest you're on too, in the Quests tab and in chat. On a
-- completed quest or an earlier step of a chain, the same tick means you've
-- done it; the others say it's in your quest log now, or not done (§9.3).
Commands.SHARED_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
Commands.LOG_ICON = "Interface\\RaidFrame\\ReadyCheck-Waiting"
Commands.MISSING_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local SHARED = "|T" .. Commands.SHARED_ICON .. ":0|t"

-- "as of 5m ago": how current a member's quest log is. That's the later of
-- its last change and the last time anything was heard from the member,
-- since a running client republishes its log as soon as it changes.
function Commands.asOf(log, seen, now)
	local at = log.rev
	if seen and seen.at and seen.at > at then
		at = seen.at
	end
	return "as of " .. Commands.age(math.max(0, now - at))
end

-- A quest's title from the client's quest data, or "Quest #id" until the
-- client has it. Only ids travel between members (§9.3).
function Commands.questTitle(store, id)
	local lookup = store.env.questTitle
	local title = lookup and lookup(id)
	if type(title) ~= "string" or title == "" then
		return format("Quest #%d", id)
	end
	return (gsub(title, "[|%[%]]", ""))
end

-- A quest link, as the client makes them. It's built locally for display
-- and never stored, so it needn't pass the sanitiser.
function Commands.questLink(id, level, title)
	return format("|cffffff00|Hquest:%d:%d|h[%s]|h|r", id, level, title)
end

-- A quest-log note's quests, by level, then title, then id: { id, level,
-- title, link, shared }, where shared means `mine` (id -> true) has it too.
-- Also returns how many are shared.
function Commands.questList(store, log, mine)
	local list, shared = {}, 0
	for _, quest in ipairs(Store.decodeQuests(log.text)) do
		local title = Commands.questTitle(store, quest.id)
		local row = {
			id = quest.id,
			level = quest.level,
			title = title,
			link = Commands.questLink(quest.id, quest.level, title),
			shared = mine[quest.id] == true,
		}
		if row.shared then
			shared = shared + 1
		end
		list[#list + 1] = row
	end
	sort(list, function(a, b)
		if a.level ~= b.level then
			return a.level < b.level
		end
		local c = Util.compare(lower(a.title), lower(b.title))
		if c ~= 0 then
			return c < 0
		end
		return a.id < b.id
	end)
	return list, shared
end

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
		out[#out + 1] = format("  %s %s(%s%s%s)|r", m.name, GREY, m.role,
			seen and seen.level and ", level " .. seen.level or "",
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

local shareQuests = option("quests", "Sharing your quest log")

local function shortName(name, me)
	local short, realm = match(name, "^([^%-]+)%-(.+)$")
	if short and realm == (me and match(me, "^[^%-]+%-(.+)$")) then
		return short
	end
	return name
end

-- The quest log `query` names: a whole name or the part before the realm, in
-- any case, or failing that the start of one. Returns the name, or nil and
-- the names it could mean when there are several.
local function findLog(logs, query)
	query = lower(query)
	local exact, partial = {}, {}
	for name in pairs(logs) do
		local full = lower(name)
		if full == query or match(full, "^([^%-]+)") == query then
			exact[#exact + 1] = name
		elseif sub(full, 1, #query) == query then
			partial[#partial + 1] = name
		end
	end
	local found = #exact > 0 and exact or partial
	if #found == 1 then
		return found[1]
	end
	sort(found, Util.less)
	return nil, #found > 1 and found or nil
end

-- /cork quests: who shares a quest log on the current board. /cork quests
-- <name>: that member's quests, marking the ones you're on too.
function handlers.quests(store, name)
	local word = lower(name)
	if word == "on" or word == "off" then
		return shareQuests(store, word)
	end
	local board, problem = current(store)
	if not board then
		return problem
	end
	local logs = Store.questLogs(board)
	local me, now, mine = store.env.me, store.env.now(), store:myQuests()
	local function asOf(who)
		return Commands.asOf(logs[who], board.seen and board.seen[who], now)
	end
	if name == "" then
		local names = {}
		for who in pairs(logs) do
			names[#names + 1] = who
		end
		if #names == 0 then
			return { format("Nobody on %s shares a quest log yet.", Store.name(board)) }
		end
		sort(names, Util.less)
		local out = { format("Quest logs on %s:", Store.name(board)) }
		for _, who in ipairs(names) do
			local list, shared = Commands.questList(store, logs[who], mine)
			if who == me then
				out[#out + 1] = format("  You: %s", plural(#list, "quest"))
			else
				out[#out + 1] = format("  %s: %s, %d shared with you %s(%s)|r", shortName(who, me),
					plural(#list, "quest"), shared, GREY, asOf(who))
			end
		end
		out[#out + 1] = GREY .. "/cork quests <name> lists someone's quests.|r"
		return out
	end
	local who, choices = findLog(logs, name)
	if not who then
		if choices then
			return { warn(format("%q could be %s.", name, concat(choices, " or "))) }
		end
		return { warn(format("Nobody called %q shares a quest log on %s.", name, Store.name(board))) }
	end
	local list, shared = Commands.questList(store, logs[who], mine)
	local out
	if who == me then
		out = { format("You're on %s, shared with %s.", plural(#list, "quest"), Store.name(board)) }
	else
		out = { format("%s is on %s %s(%s)|r. You share %d.", shortName(who, me), plural(#list, "quest"), GREY,
			asOf(who), shared) }
	end
	for _, quest in ipairs(list) do
		local level = quest.level > 0 and format(" %s(%d)|r", GREY, quest.level) or ""
		out[#out + 1] = "  " .. quest.link .. level .. (quest.shared and who ~= me and " " .. SHARED or "")
	end
	-- The last few turned in; the Quests tab lists them all, chains grouped.
	local done = Store.decodeDone(logs[who].text)
	if #done > 0 then
		local recent = {}
		for i = 1, math.min(#done, Commands.RECENT_DONE) do
			local entry = done[i]
			recent[i] = Commands.questLink(entry.id, entry.level, Commands.questTitle(store, entry.id))
				.. format(" %s(%s)|r", GREY, Commands.shortAge(math.max(0, now - entry.at)))
		end
		local more = #done > #recent and format(" %sand %d more on the Quests tab|r", GREY, #done - #recent) or ""
		out[#out + 1] = "Last turned in: " .. concat(recent, ", ") .. more
	end
	return out
end

-- Player notes (§9.4) ------------------------------------------------------------

-- The verdict in the game's red or green, for chat.
Commands.VERDICT_CODES = { avoid = "|cffff2020", good = "|cff19ff19" }

local function verdict(entry)
	return Commands.VERDICT_CODES[entry.verdict] .. Players.LABELS[entry.verdict] .. "|r"
end

-- One entry as a chat line: "Avoid: why (Will on Raid, 2d ago)". The reason
-- keeps its links, on one line.
local function playerLine(entry, me, now)
	local reason = gsub(entry.reason, "\n", " ")
	return format("%s%s %s(%s on %s, %s)|r", verdict(entry), reason ~= "" and ": " .. reason or "", GREY,
		shortName(entry.note.author, me), Store.name(entry.board), Commands.age(math.max(0, now - entry.note.rev)))
end

-- The chat warning when a player your boards say to avoid is in your group.
-- `found` is Players.lookup's list, avoid entries first.
function Commands.playerWarning(found, me, now)
	local first = found[1]
	local line = format("%s is in your group. %s", first.name, playerLine(first, me, now))
	if #found > 1 then
		line = line .. format(" %s(/cork player %s for %s more)|r", GREY, first.name, #found - 1)
	end
	return line
end

-- /cork player <name>: every entry about that player on any of your boards.
function handlers.player(store, name)
	if not Players.key(name) then
		return { "Usage: /cork player <name>. Add players on the Players tab in /cork." }
	end
	local found = Players.lookup(store:boards(), name)
	if #found == 0 then
		return { format("None of your boards have a note about %s.", name) }
	end
	local me, now = store.env.me, store.env.now()
	local out = { format("%s on your boards:", name) }
	for _, entry in ipairs(found) do
		local who = entry.name ~= name and format("%s ", entry.name) or ""
		out[#out + 1] = "  " .. who .. playerLine(entry, me, now)
	end
	return out
end

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
