-- The logic behind the board window and note editor (docs/design.md §9,
-- docs/ui-style.md): search, layout rows, labels and editor checks. Pure Lua
-- 5.1, so busted tests it; the frames in UI/ only draw what this returns.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Commands = ns.Commands or require("Core.Commands")
local plural = Commands.plural

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
View.shortAge = Commands.shortAge

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

-- The note count on the right of the status line.
function View.count(noteCount, shownCount)
	if noteCount == shownCount then
		return plural(noteCount, "note")
	end
	return format("%d of %d notes", shownCount, noteCount)
end

-- Status dot colours from docs/ui-style.md.
View.DOTS = {
	synced = rgb("4f9a47"),
	syncing = rgb("5a8cc0"),
	paused = rgb("b8903a"),
	behind = rgb("b8663a"),
	idle = rgb("7a7a7a"),
}

local function cloudDetail(status, now)
	if not status.cloud then
		return "· cloud off"
	elseif status.lastCloudAt then
		return "· Cloud " .. Commands.age(now - status.lastCloudAt)
	end
	return "· cloud not synced yet"
end

-- The status line for a board (docs/mockups/SyncStates): { label, detail,
-- dot, hollow, dim }. `status` comes from Sync:status, `channel` from
-- Net:ChannelState ("joined", "joining", "guild", "expired" or "limit").
function View.syncStatus(status, channel, now, myRealm)
	if channel == "expired" then
		return { label = "Invite out of date", detail = "· ask the owner for a new one", dot = "behind" }
	elseif status.paused then
		local detail = status.queued > 0 and format("· %s queued", plural(status.queued, "message")) or "· sends when allowed"
		return { label = "Paused", detail = detail, dot = "paused" }
	elseif status.behind then
		return { label = format("%s behind", plural(status.behind, "note")), detail = "· /reload after cloud sync",
			dot = "behind" }
	elseif status.syncing then
		return { label = "Syncing", detail = format("· %s from %s", plural(status.syncing.left, "note"),
			View.shortName(status.syncing.from, myRealm)), dot = "syncing", hollow = true }
	elseif channel == "limit" then
		return { label = "Not connected", detail = "· only 3 boards sync live at once", dot = "idle", dim = true }
	elseif channel == "joining" then
		return { label = "Connecting", detail = cloudDetail(status, now), dot = "idle", hollow = true, dim = true }
	elseif #status.online > 0 then
		if status.lastPeer and status.lastPeerAt then
			return { label = format("Synced with %s %s", View.shortName(status.lastPeer, myRealm),
				Commands.age(now - status.lastPeerAt)), detail = cloudDetail(status, now), dot = "synced" }
		end
		return { label = format("%d online", #status.online), detail = cloudDetail(status, now), dot = "synced" }
	elseif not status.cloud then
		return { label = "In-game sync only", detail = "· cloud off", dot = "idle", dim = true }
	end
	return { label = "Nobody online", detail = cloudDetail(status, now), dot = "idle", hollow = true, dim = true }
end

-- The line under a board's name in the board list.
function View.boardDetail(noteCount, online)
	local notes = plural(noteCount, "note")
	if online and online > 0 then
		return format("%s · %d online", notes, online)
	end
	return notes
end

-- "3 hours", "2 days": how long ago a member was seen, for the roster.
function View.seen(seconds)
	if seconds < 3600 then
		return plural(math.max(1, floor(seconds / 60)), "minute")
	elseif seconds < 86400 then
		return plural(floor(seconds / 3600), "hour")
	end
	return plural(floor(seconds / 86400), "day")
end

-- The Members tab roster (docs/mockups/Share): one row per member.
function View.memberRows(board, members, peers, online, me, now, myRealm)
	local isOnline = {}
	for _, name in ipairs(online) do
		isOnline[name] = true
	end
	local rows = {}
	for _, m in ipairs(members) do
		local seen = board.seen and board.seen[m.name]
		local peer = peers and peers[m.name]
		local row = {
			name = m.name,
			label = View.shortName(m.name, myRealm),
			role = m.role == "owner" and "Owner" or "Member",
			class = seen and seen.class,
			online = m.name == me or isOnline[m.name] == true,
			removable = board.owner == me and m.name ~= me,
		}
		if m.name == me then
			row.seen, row.sync = "You", "-"
		elseif row.online then
			row.seen = "Online"
			row.sync = peer and peer.state == "match" and "Up to date" or "Syncing"
		else
			row.seen = seen and View.seen(now - seen.at) or "Never"
			row.sync = peer and peer.cloud and "Cloud " .. Commands.age(now - peer.cloud) or "-"
		end
		rows[#rows + 1] = row
	end
	return rows
end

-- The minimap / broker tooltip (docs/mockups/SyncStates): each board and
-- its state, as { text, r, g, b } lines.
function View.tooltipLines(store, sync)
	local lines = {}
	local grey = { 0.62, 0.62, 0.62 }
	for i, board in ipairs(store:boards()) do
		if i > 8 then
			lines[#lines + 1] = { format("and %d more", #store:boards() - 8), grey[1], grey[2], grey[3] }
			break
		end
		local status = sync:status(board.id)
		local detail
		if status.queued > 0 and status.paused then
			detail = format("%d queued", status.queued)
		elseif #status.online > 0 then
			detail = format("%d online", #status.online)
		else
			detail = "Nobody online"
		end
		lines[#lines + 1] = { board.meta and board.meta.name or board.id, 1, 1, 1 }
		lines[#lines + 1] = { "  " .. detail, grey[1], grey[2], grey[3] }
	end
	return lines
end

-- The debug panel's stats (docs/mockups/Debug): { key, value } pairs.
function View.debugStats(outbox, gateName, board, now)
	local stats = outbox.stats
	local gate = outbox.gate.open and "Open" or format("Closed (%s)", tostring(outbox.gate.reason))
	local closed = outbox.lastClosed
	return {
		{ "Send gate", gate .. " · " .. gateName },
		{ "Last closed", closed and format("%s ago (%s)", View.shortAge(now - closed.at), tostring(closed.reason))
			or "never" },
		{ "Outbox", tostring(outbox:depth()) },
		{ "Throttle stalls", stats.lastStall and format("%d (%s ago)", stats.stalls, View.shortAge(now - stats.lastStall))
			or "0" },
		{ "Sent", format("%d envelopes, %d messages, %d B", stats.envelopes, stats.messages, stats.bytes) },
		{ "Refused", format("%d restricted, %d failed, %d too long", stats.lockdowns, stats.errors, stats.dropped) },
		{ "Budget", format("%.1f / %d messages", outbox.tokens, outbox.burst) },
		{ "Board clock", board and Util.formatInt(board.clock or 0) or "-" },
	}
end

-- "45:1790004412:9f3a01c2": a peer's count, clock and digest, for the peers table.
function View.digestLabel(count, clock, digest)
	return format("%d:%s:%08x", count or 0, Util.formatInt(clock or 0), digest or 0)
end

ns.View = View
return View
