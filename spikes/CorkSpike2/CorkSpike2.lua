-- CorkSpike2: throwaway Phase 0 spike for Corkboard (docs/spikes/03 to 06).
--
--   03  password-protected channel reach, the per-character channel limit, and
--       whether a hidden channel ever shows in a chat frame
--   04  links: what each kind looks like on Forever, whether Corkboard's
--       sanitiser accepts it, and whether it survives the LibSerialize +
--       LibDeflate addon-channel round trip byte for byte. Also which link
--       inserter a shift-click calls (a Phase 1 question).
--   05  BNSendGameData: payload size limit and throttle
--   06  the SavedVariables fresh-launch bug, and what the client says about
--       its own product (the companion side is spikes/install_probe.py)
--
-- Like CorkSpike, it calls C_ChatInfo.SendAddonMessage and BNSendGameData
-- directly, on purpose. Corkboard itself must never do that (§5.5, §5.6).
-- /cspike2 report opens a copyable Markdown report. See README.md.

local ADDON_NAME = ...

local PREFIX = "CORKSPK5" -- channel pings and BNet runs
local PREFIX_LINKS = "CORKSPK4" -- link round trip
local CHUNK = 250 -- bytes of payload per addon message in the link round trip

local now = GetTimePreciseSec or GetTime
local SendAddon = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
-- Looked up on each call: C_BattleNet.SendGameData on newer clients, else the global.
local function BNSend(id, prefix, text)
	if C_BattleNet and C_BattleNet.SendGameData then
		return C_BattleNet.SendGameData(id, prefix, text)
	end
	return BNSendGameData(id, prefix, text)
end

local db -- CorkSpike2DB
local session
local me, myName, myRealm
local job

-- Output --------------------------------------------------------------------

local function escape(v)
	return (tostring(v):gsub("|", "!"))
end

local function show(v)
	if issecretvalue and issecretvalue(v) then
		return "<secret>"
	end
	if type(v) == "string" then
		return '"' .. escape(v) .. '"'
	end
	return tostring(v)
end

local function say(fmt, ...)
	local line = select("#", ...) > 0 and fmt:format(...) or fmt
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100CorkSpike2:|r " .. line)
	if session then
		local log = session.log
		log[#log + 1] = ("%7.2f  %s"):format(now() - session.t0, escape(line))
		if #log > 1500 then
			table.remove(log, 1)
		end
	end
end

local function passed(ok, ...)
	if ok then
		return ...
	end
end

-- Calls fn if it exists, returning all its results, or nothing if it errors.
local function safe(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	return passed(pcall(fn, ...))
end

-- All of safe(fn, ...)'s results as a list.
local function list(fn, ...)
	return { safe(fn, ...) }
end

-- Every return value of a pcall, as text.
local function results(ok, ...)
	if not ok then
		return "error: " .. escape((...))
	end
	local n = select("#", ...)
	if n == 0 then
		return "(no return)"
	end
	local parts = {}
	for i = 1, n do
		parts[i] = show((select(i, ...)))
	end
	return table.concat(parts, ", ")
end

local function refreshMe()
	local name, realm = UnitFullName("player")
	realm = (realm and realm ~= "") and realm or safe(GetNormalizedRealmName)
	myName, myRealm = name, realm
	me = realm and (name .. "-" .. realm) or name
end

-- Script runner (same idea as CorkSpike) -------------------------------------

local function wait(seconds)
	job.wake = now() + seconds
	coroutine.yield()
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function()
	if not job or now() < job.wake then
		return
	end
	local current = job
	local ok, err = coroutine.resume(current.co)
	if not ok then
		say("|cffff2020error in %s:|r %s", current.name, tostring(err))
		job = nil
	elseif coroutine.status(current.co) == "dead" then
		say("%s finished. Type /cspike2 report to see the results.", current.name)
		job = nil
	end
end)

local function start(name, fn, ...)
	if job then
		say("still running %s; /cspike2 stop first.", job.name)
		return
	end
	refreshMe()
	local args = { n = select("#", ...), ... }
	job = {
		name = name,
		wake = 0,
		co = coroutine.create(function()
			fn(unpack(args, 1, args.n))
		end),
	}
	say("started %s.", name)
end

-- Spike 03: channels ------------------------------------------------------------

local notices = {} -- CHAT_MSG_CHANNEL_NOTICE(_USER) seen since the last take

local function takeNotices()
	local out = notices
	notices = {}
	return out
end

local function channelList()
	if not GetChannelList then
		return "?"
	end
	-- GetChannelList returns id, name, disabled triples.
	local channels, out = list(GetChannelList), {}
	for i = 1, #channels, 3 do
		out[#out + 1] = ("%s. %s"):format(tostring(channels[i]), escape(channels[i + 1]))
	end
	return #out > 0 and table.concat(out, ", ") or "none"
end

-- Removes a channel from every chat frame, by whichever function this client has.
local function hideChannel(name)
	local used = {}
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local frame = _G["ChatFrame" .. i]
		if frame then
			if ChatFrame_RemoveChannel and pcall(ChatFrame_RemoveChannel, frame, name) then
				used.ChatFrame_RemoveChannel = true
			elseif ChatFrameUtil and ChatFrameUtil.RemoveChannel and pcall(ChatFrameUtil.RemoveChannel, frame, name) then
				used["ChatFrameUtil.RemoveChannel"] = true
			elseif frame.RemoveChannel and pcall(frame.RemoveChannel, frame, name) then
				used["frame:RemoveChannel"] = true
			end
		end
	end
	local names = {}
	for k in pairs(used) do
		names[#names + 1] = k
	end
	return #names > 0 and table.concat(names, ", ") or "nothing worked"
end

-- Which chat frames still list the channel.
local function framesListing(name)
	local out = {}
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		-- GetChatWindowChannels returns name, zone pairs.
		local channels = list(GetChatWindowChannels, i)
		for k = 1, #channels, 2 do
			if type(channels[k]) == "string" and channels[k]:lower() == name:lower() then
				out[#out + 1] = "ChatFrame" .. i
			end
		end
	end
	return #out > 0 and table.concat(out, ", ") or "none"
end

local function joinAndWait(name, password)
	local ret = results(pcall(JoinTemporaryChannel, name, password))
	for _ = 1, 20 do
		local id = safe(GetChannelName, name)
		if id and id > 0 then
			return id, ret
		end
		wait(0.1)
	end
	return nil, ret
end

local function channelLimit()
	local s = { before = channelList(), joins = {} }
	session.limit = s
	takeNotices()
	local base = "CkLim" .. math.random(1000, 9999)
	for i = 1, 15 do
		local name = base .. i
		local id, ret = joinAndWait(name, "pw" .. math.random(100000, 999999))
		wait(1)
		local entry = { name = name, id = id, ret = ret, notices = takeNotices() }
		s.joins[#s.joins + 1] = entry
		say("join %d (%s): %s", i, name, id and ("id " .. id) or "failed")
		if not id then
			break
		end
	end
	s.during = channelList()
	for _, entry in ipairs(s.joins) do
		if entry.id then
			safe(LeaveChannelByName, entry.name)
		end
	end
	wait(2)
	s.after = channelList()
	s.leaveNotices = takeNotices()
end

local reach -- the running reach test

local function reachOff()
	if reach then
		reach.ticker:Cancel()
		safe(LeaveChannelByName, reach.name)
		say("left %s after %d pings.", reach.name, reach.seq)
		reach = nil
	end
end

local function reachOn(name, password)
	reachOff()
	takeNotices()
	local id, ret = joinAndWait(name, password)
	local r = session.reach or { peers = {}, joins = {} }
	session.reach = r
	local attempt = { name = name, id = id, ret = ret, realm = myRealm }
	r.joins[#r.joins + 1] = attempt
	wait(1)
	attempt.notices = takeNotices()
	if not id then
		say("couldn't join %s: %s", name, ret)
		return
	end
	attempt.hiddenWith = hideChannel(name)
	wait(0.5)
	attempt.stillListedIn = framesListing(name)
	say("joined %s (id %d), hidden with %s, still listed in: %s", name, id, attempt.hiddenWith, attempt.stillListedIn)
	reach = { name = name, id = id, seq = 0 }
	reach.ticker = C_Timer.NewTicker(5, function()
		reach.seq = reach.seq + 1
		local id2 = safe(GetChannelName, name) or id
		local payload = ("ping:%d:%s:%s"):format(reach.seq, tostring(myRealm), tostring(safe(UnitFactionGroup, "player")))
		local result = results(pcall(SendAddon, PREFIX, payload, "CHANNEL", tostring(id2)))
		if result ~= reach.lastResult then
			say("ping result: %s", result)
			reach.lastResult = result
		end
	end)
end

local function onPing(text, sender)
	local r = session.reach
	if not r then
		return
	end
	local seq, realm, faction = text:match("^ping:(%d+):([^:]*):(.*)$")
	if not seq then
		return
	end
	local key = sender == me and "self" or (sender .. " (" .. realm .. ", " .. faction .. ")")
	local p = r.peers[key] or { n = 0, first = now() - session.t0 }
	r.peers[key] = p
	p.n = p.n + 1
	p.last = now() - session.t0
end

-- Spike 04: links -------------------------------------------------------------------

local captured = {} -- links shift-clicked while capturing
local capturing = false
local hooked = {}

local function hookInserts()
	local function hook(label)
		return function(link)
			if capturing and link then
				captured[#captured + 1] = { link = link, via = label, chatOpen = ChatEdit_GetActiveWindow
					and ChatEdit_GetActiveWindow() ~= nil or nil }
				say("captured via %s: %s", label, escape(link))
			end
		end
	end
	if ChatFrameUtil and ChatFrameUtil.InsertLink and not hooked.util then
		hooksecurefunc(ChatFrameUtil, "InsertLink", hook("ChatFrameUtil.InsertLink"))
		hooked.util = true
	end
	if ChatEdit_InsertLink and not hooked.edit then
		hooksecurefunc("ChatEdit_InsertLink", hook("ChatEdit_InsertLink"))
		hooked.edit = true
	end
end

local function libs()
	local stub = LibStub
	if not stub then
		return nil
	end
	return stub("LibSerialize", true), stub("LibDeflate", true)
end

local function corkboard()
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	return ace and ace:GetAddon("Corkboard", true)
end

local function linkTypes(link)
	local types = {}
	for kind in link:gmatch("|H([^:|]*):") do
		types[#types + 1] = kind
	end
	return table.concat(types, ",")
end

local function escapes(link)
	local seen, out = {}, {}
	for code in link:gmatch("|(%a)") do
		if not seen[code] then
			seen[code] = true
			out[#out + 1] = "|" .. code
		end
	end
	if link:find("|cn", 1, true) then
		out[#out + 1] = "|cn (named colour)"
	end
	return escape(table.concat(out, " "))
end

-- Links the client can build without the player clicking anything.
local function gatherLinks()
	local out = {}
	local function add(source, link)
		if type(link) == "string" and link ~= "" then
			out[#out + 1] = { source = source, link = link }
		end
	end
	local container = C_Container
	for bag = 0, 4 do
		local slots = container and safe(container.GetContainerNumSlots, bag) or 0
		for slot = 1, slots do
			if #out < 12 then
				add("bag", safe(container.GetContainerItemLink, bag, slot))
			end
		end
	end
	local numQuests = C_QuestLog and safe(C_QuestLog.GetNumQuestLogEntries) or 0
	local quests = 0
	for i = 1, numQuests do
		local info = safe(C_QuestLog.GetInfo, i)
		if info and not info.isHeader and info.questID and quests < 5 then
			add("quest log", safe(GetQuestLink, info.questID))
			quests = quests + 1
		end
	end
	local spellLink = (C_Spell and C_Spell.GetSpellLink) or GetSpellLink
	for _, id in ipairs({ 6603, 8690, 133, 585, 78, 2050, 1459 }) do
		add("spell " .. id, safe(spellLink, id))
	end
	add("achievement 6", safe(GetAchievementLink, 6))
	add("currency 1", C_CurrencyInfo and safe(C_CurrencyInfo.GetCurrencyLink, 1))
	add("item 6948 (GetItemInfo)", select(2, safe(C_Item and C_Item.GetItemInfo or GetItemInfo, 6948)))
	for _, c in ipairs(captured) do
		add("shift-click (" .. c.via .. ")", c.link)
	end
	return out
end

local function tooltipResult(link)
	local ok, err = pcall(function()
		GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
		GameTooltip:SetHyperlink(link)
	end)
	local lines = ok and safe(GameTooltip.NumLines, GameTooltip) or 0
	safe(GameTooltip.Hide, GameTooltip)
	return ok and ("ok, %d lines"):format(lines or 0) or ("error: " .. escape(err))
end

local function encode(Serialize, Deflate, value)
	local s = Serialize:Serialize(value)
	return Deflate:EncodeForWoWAddonChannel(Deflate:CompressDeflate(s))
end

local function decode(Serialize, Deflate, text)
	local raw = Deflate:DecompressDeflate(Deflate:DecodeForWoWAddonChannel(text))
	if not raw then
		return nil
	end
	local ok, value = Serialize:Deserialize(raw)
	return ok and value or nil
end

local linkRun -- the running link round trip: pending messages by id

local function runLinks()
	local Serialize, Deflate = libs()
	local cb = corkboard()
	local Sanitise = cb and cb.Sanitise
	local s = { rows = {}, libs = Serialize and Deflate and "yes" or "no (enable Corkboard, which carries them)",
		sanitiser = Sanitise and "Corkboard's" or "not available (enable Corkboard)" }
	session.links = s
	linkRun = { pending = {}, parts = {} }
	for i, item in ipairs(gatherLinks()) do
		local link = item.link
		local row = { n = i, source = item.source, raw = escape(link), bytes = #link, types = linkTypes(link),
			escapes = escapes(link), tooltip = tooltipResult(link) }
		if Sanitise then
			local ok, reason = Sanitise.text(link)
			row.sanitiser = ok and "ok" or ("rejected: " .. tostring(reason))
		end
		if Serialize and Deflate then
			local text = encode(Serialize, Deflate, { id = i, text = link })
			local back = decode(Serialize, Deflate, text)
			row.localTrip = back and back.text == link and "intact" or "changed"
			row.wire = #text
			-- Loopback: whisper ourselves in plain chunks: "<id>:<index>:<count>:" .. part.
			local count = math.ceil(#text / CHUNK)
			row.sent = {}
			linkRun.pending[i] = { row = row, link = link, count = count }
			for k = 1, count do
				local part = ("%d:%d:%d:"):format(i, k, count) .. text:sub((k - 1) * CHUNK + 1, k * CHUNK)
				row.sent[#row.sent + 1] = results(pcall(SendAddon, PREFIX_LINKS, part, "WHISPER", me))
				wait(1.2) -- about one message a second
			end
		end
		s.rows[#s.rows + 1] = row
		say("link %d (%s): types %s, sanitiser %s, tooltip %s", i, item.source, row.types, tostring(row.sanitiser),
			row.tooltip)
	end
	wait(3)
	for _, p in pairs(linkRun.pending) do
		p.row.netTrip = p.row.netTrip or "not received"
	end
end

local function onLinkPart(text)
	if not linkRun then
		return
	end
	local id, k, count, part = text:match("^(%d+):(%d+):(%d+):(.*)$")
	local p = id and linkRun.pending[tonumber(id)]
	if not p then
		return
	end
	local parts = linkRun.parts[p] or {}
	linkRun.parts[p] = parts
	parts[tonumber(k)] = part
	for i = 1, tonumber(count) do
		if not parts[i] then
			return
		end
	end
	local Serialize, Deflate = libs()
	local back = decode(Serialize, Deflate, table.concat(parts))
	p.row.netTrip = back and back.text == p.link and "intact" or "changed"
end

-- Spike 05: BNet ----------------------------------------------------------------------

local bnetTarget

local function listBnet()
	local count = safe(BNGetNumFriends) or 0
	local listed = 0
	for i = 1, count do
		local info = C_BattleNet and safe(C_BattleNet.GetFriendAccountInfo, i)
		local game = info and info.gameAccountInfo
		if game and game.isOnline and game.gameAccountID and game.clientProgram == (BNET_CLIENT_WOW or "WoW") then
			say("BNet friend %d: %s on %s, gameAccountID %s, wowProjectID %s", i, tostring(game.characterName),
				tostring(game.realmName), tostring(game.gameAccountID), tostring(game.wowProjectID))
			listed = listed + 1
		end
	end
	if listed == 0 then
		say("no BNet friends are online in WoW.")
	end
end

local function bnetPayload(tag, size)
	local head = tag .. ":" .. size .. ":"
	return head .. ("x"):rep(math.max(0, size - #head))
end

local function bnetSizes()
	local s = { target = "a BNet friend", sizes = {}, api = C_BattleNet and C_BattleNet.SendGameData
		and "C_BattleNet.SendGameData" or (BNSendGameData and "BNSendGameData" or "missing") }
	session.bnet = s
	for _, size in ipairs({ 16, 255, 256, 1000, 2000, 4000, 4078, 4079, 4093, 4096, 8000 }) do
		local result = results(pcall(BNSend, bnetTarget, PREFIX, bnetPayload("sz", size)))
		s.sizes[#s.sizes + 1] = { size = size, result = result }
		say("BNet %d bytes: %s", size, result)
		wait(1.5)
	end
end

local function bnetRate(size)
	local s = session.bnet or { sizes = {} }
	session.bnet = s
	wait(30)
	local burst = { size = size, results = {} }
	for i = 1, 40 do
		local r = results(pcall(BNSend, bnetTarget, PREFIX, bnetPayload("b" .. i, size)))
		burst.results[r] = (burst.results[r] or 0) + 1
	end
	s.burst = burst
	say("BNet burst of 40 x %d B sent in one frame.", size)
	wait(30)
	local rate = { size = size, results = {}, attempts = 0 }
	local stop = now() + 30
	while now() < stop do
		rate.attempts = rate.attempts + 1
		local r = results(pcall(BNSend, bnetTarget, PREFIX, bnetPayload("r" .. rate.attempts, size)))
		rate.results[r] = (rate.results[r] or 0) + 1
		job.wake = 0
		coroutine.yield()
	end
	s.rate = rate
	say("BNet rate: %d attempts over 30 s.", rate.attempts)
end

local function onBnet(prefix, text, senderID)
	if prefix ~= PREFIX then
		return
	end
	local r = session.bnetIn or { sizes = {}, burst = 0, rate = 0 }
	session.bnetIn = r
	local tag, size = text:match("^(%w+):(%d+):")
	size = tonumber(size)
	if tag == "sz" then
		r.sizes[#r.sizes + 1] = ("%d bytes (%s)"):format(#text, #text == size and "intact" or "size changed")
	elseif tag and tag:find("^b") then
		r.burst = r.burst + 1
	elseif tag and tag:find("^r") then
		r.rate = r.rate + 1
		r.rateFirst = r.rateFirst or now()
		r.rateLast = now()
	end
	r.sender = tostring(senderID)
end

-- Spike 06: SavedVariables and product ----------------------------------------------------

local function projectInfo()
	local out = {}
	for name, value in pairs(_G) do
		if type(name) == "string" and name:find("^WOW_PROJECT_") then
			out[#out + 1] = ("%s=%s"):format(name, tostring(value))
		end
	end
	table.sort(out)
	return table.concat(out, ", ")
end

local function clientInfo()
	local version, build, buildDate, toc = safe(GetBuildInfo)
	return {
		build = ("%s (build %s, %s), TOC %s"):format(tostring(version), tostring(build), tostring(buildDate),
			tostring(toc)),
		projects = projectInfo(),
		region = tostring(safe(GetCurrentRegionName)),
		portal = tostring(safe(GetCVar, "portal")),
		locale = tostring(safe(GetLocale)),
	}
end

-- Report -------------------------------------------------------------------------------------

local function buildReport(s)
	local out = {}
	local function line(fmt, ...)
		out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
	end
	local c = s.client or {}
	line("## CorkSpike2 report")
	line("")
	line("- Run at: %s (local time)", s.date or "?")
	line("- Client: %s", c.build or "?")
	line("- `WOW_PROJECT_*`: %s", c.projects or "?")
	line("- Region: %s, portal CVar: %s, locale: %s", c.region or "?", c.portal or "?", c.locale or "?")

	line("")
	line("### Spike 03: channels")
	if s.limit then
		line("")
		line("Channels before: %s", s.limit.before)
		line("")
		line("| # | Name | Result | JoinTemporaryChannel returned | Notices |")
		line("|---|---|---|---|---|")
		for i, j in ipairs(s.limit.joins) do
			line("| %d | %s | %s | %s | %s |", i, j.name, j.id and ("id " .. j.id) or "failed", j.ret,
				table.concat(j.notices, "; "))
		end
		line("")
		line("Channels at the limit: %s", s.limit.during)
		line("Channels after leaving: %s", s.limit.after)
		line("Notices while leaving: %s", table.concat(s.limit.leaveNotices or {}, "; "))
	end
	if s.reach then
		line("")
		for _, j in ipairs(s.reach.joins) do
			line("- Joined `%s` from realm %s: %s. Returned %s. Hidden with %s. Still listed in: %s. Notices: %s",
				j.name, tostring(j.realm), j.id and ("id " .. j.id) or "failed", j.ret, tostring(j.hiddenWith),
				tostring(j.stillListedIn), table.concat(j.notices or {}, "; "))
		end
		line("- Pings heard:")
		for key, p in pairs(s.reach.peers) do
			line("  - %s: %d pings, first %.0f s, last %.0f s", escape(key), p.n, p.first, p.last or p.first)
		end
		line("- Visible channel text for these channels: %d lines", s.channelText or 0)
	end

	line("")
	line("### Spike 04: links")
	if s.links then
		line("")
		line("Libraries: %s. Sanitiser: %s.", s.links.libs, s.links.sanitiser)
		line("")
		line("| # | Source | Types | Escapes | Bytes | Sanitiser | Tooltip | Local trip | Wire bytes | Network trip |")
		line("|---|---|---|---|---|---|---|---|---|---|")
		for _, r in ipairs(s.links.rows) do
			line("| %d | %s | %s | %s | %d | %s | %s | %s | %s | %s |", r.n, r.source, r.types, r.escapes, r.bytes,
				tostring(r.sanitiser or "-"), r.tooltip, tostring(r.localTrip or "-"), tostring(r.wire or "-"),
				tostring(r.netTrip or "-"))
		end
		line("")
		line("Raw links (| written as !):")
		line("")
		line("```")
		for _, r in ipairs(s.links.rows) do
			line("%d  %s", r.n, r.raw)
		end
		line("```")
	end
	if s.capture then
		line("")
		line("Shift-click capture: %s", s.capture)
	end

	line("")
	line("### Spike 05: BNet")
	if s.bnet then
		line("")
		line("API: %s", tostring(s.bnet.api))
		line("")
		line("| Bytes | Result |")
		line("|---|---|")
		for _, r in ipairs(s.bnet.sizes or {}) do
			line("| %d | %s |", r.size, r.result)
		end
		for _, key in ipairs({ "burst", "rate" }) do
			local b = s.bnet[key]
			if b then
				local parts = {}
				for k, n in pairs(b.results) do
					parts[#parts + 1] = ("%s x%d"):format(k, n)
				end
				line("- %s, %d B: %s%s", key, b.size, table.concat(parts, "; "),
					b.attempts and (" (%d attempts)"):format(b.attempts) or "")
			end
		end
	end
	if s.bnetIn then
		local r = s.bnetIn
		line("- Received from %s: sizes %s; burst %d of 40; rate %d%s", r.sender or "?",
			table.concat(r.sizes, ", "), r.burst, r.rate, r.rateFirst
				and (" over %.1f s"):format((r.rateLast or r.rateFirst) - r.rateFirst) or "")
	end

	line("")
	line("### Spike 06: SavedVariables")
	line("")
	line("| Loaded at | Initial login | Reload | SavedVariables found | Last logout stamp |")
	line("|---|---|---|---|---|")
	for _, l in ipairs(db and db.loads or {}) do
		line("| %s | %s | %s | %s | %s |", l.at, tostring(l.initial), tostring(l.reload), tostring(l.found),
			tostring(l.stamp))
	end

	line("")
	line("### Log")
	line("")
	line("```")
	for i = math.max(1, #s.log - 300), #s.log do
		line(s.log[i])
	end
	line("```")
	return table.concat(out, "\n")
end

local reportFrame

local function showReport(text)
	if not reportFrame then
		local f = CreateFrame("Frame", "CorkSpike2ReportFrame", UIParent, "BasicFrameTemplateWithInset")
		f:SetSize(780, 540)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		if not f.TitleText then
			title:SetPoint("TOP", 0, -5)
		end
		title:SetText("CorkSpike2 report: the text is selected, press Ctrl+C to copy")
		local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 14, -32)
		scroll:SetPoint("BOTTOMRIGHT", -34, 14)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject(ChatFontNormal)
		edit:SetWidth(720)
		edit:SetMaxLetters(0)
		edit:SetScript("OnEscapePressed", function()
			f:Hide()
		end)
		scroll:SetScrollChild(edit)
		f.edit = edit
		table.insert(UISpecialFrames, "CorkSpike2ReportFrame")
		reportFrame = f
	end
	reportFrame:Show()
	reportFrame.edit:SetText(text)
	reportFrame.edit:SetFocus()
	reportFrame.edit:HighlightText()
end

-- Events ---------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
for _, event in ipairs({
	"ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "CHAT_MSG_ADDON",
	"BN_CHAT_MSG_ADDON", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL",
}) do
	pcall(events.RegisterEvent, events, event)
end

local function isOurChannel(name)
	name = type(name) == "string" and name:lower() or ""
	return name:find("cklim", 1, true) or (reach and name:find(reach.name:lower(), 1, true))
end

events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON_NAME then
			return
		end
		local found = CorkSpike2DB ~= nil
		CorkSpike2DB = CorkSpike2DB or {}
		db = CorkSpike2DB
		db.loads = db.loads or {}
		while #db.loads >= 10 do
			table.remove(db.loads, 1)
		end
		db.loads[#db.loads + 1] = { at = date("%Y-%m-%d %H:%M:%S"), found = found, stamp = db.logoutStamp }
		db.sessions = db.sessions or {}
		while #db.sessions >= 3 do
			table.remove(db.sessions, 1)
		end
		session = { t0 = now(), log = {}, date = date("%Y-%m-%d %H:%M") }
		db.sessions[#db.sessions + 1] = session
	elseif event == "PLAYER_LOGIN" then
		for _, prefix in ipairs({ PREFIX, PREFIX_LINKS }) do
			pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
		end
		session.client = clientInfo()
		refreshMe()
	elseif event == "PLAYER_ENTERING_WORLD" then
		local initial, reload = ...
		local load = db and db.loads[#db.loads]
		if load and load.initial == nil then
			load.initial, load.reload = initial, reload
		end
	elseif event == "PLAYER_LOGOUT" then
		db.logoutStamp = date("%Y-%m-%d %H:%M:%S")
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, text, _, sender = ...
		if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(sender)) then
			session.secret = (session.secret or 0) + 1
			return
		end
		if prefix == PREFIX then
			onPing(text, sender)
		elseif prefix == PREFIX_LINKS and (sender == me or sender == myName) then
			onLinkPart(text)
		end
	elseif event == "BN_CHAT_MSG_ADDON" then
		local prefix, text, _, senderID = ...
		if not (issecretvalue and issecretvalue(text)) then
			onBnet(prefix, text, senderID)
		end
	elseif event == "CHAT_MSG_CHANNEL_NOTICE" or event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
		local notice, _, _, channelString, _, _, _, _, channelName = ...
		local name = channelName or channelString
		if isOurChannel(name) or isOurChannel(channelString) then
			notices[#notices + 1] = ("%s %s"):format(escape(notice), escape(name))
			say("%s: %s %s", event, show(notice), show(name))
		end
	elseif event == "CHAT_MSG_CHANNEL" then
		local _, _, _, channelString, _, _, _, _, channelName = ...
		if isOurChannel(channelName) or isOurChannel(channelString) then
			session.channelText = (session.channelText or 0) + 1
		end
	end
end)

-- Slash command -----------------------------------------------------------------------------------

local HELP = {
	"/cspike2 limit: join temporary channels until the client refuses (spike 03).",
	"/cspike2 reach <name> <password> | reach off: join a channel and ping it every 5 s (spike 03).",
	"/cspike2 capture: for 2 minutes, record every link you shift-click (spike 04).",
	"/cspike2 links: check every link (sanitiser, tooltip, round trip). Enable Corkboard first (spike 04).",
	"/cspike2 bnet [gameAccountID]: list BNet friends, or pick one (spike 05).",
	"/cspike2 bnetsize | bnetrate [bytes]: payload sizes, or burst and rate (spike 05).",
	"/cspike2 report: open the copyable report. /cspike2 stop: abort.",
}

SLASH_CORKSPIKETWO1 = "/cspike2"
SlashCmdList.CORKSPIKETWO = function(input)
	local args = {}
	for word in input:gmatch("%S+") do
		args[#args + 1] = word
	end
	local cmd = (args[1] or "help"):lower()
	refreshMe()
	if cmd == "limit" then
		start("the channel limit", channelLimit)
	elseif cmd == "reach" and args[2] and args[2]:lower() == "off" then
		reachOff()
	elseif cmd == "reach" and args[2] then
		start("the channel reach test", reachOn, args[2], args[3] or "")
	elseif cmd == "capture" then
		hookInserts()
		capturing = true
		captured = {}
		say("capturing for 2 minutes: shift-click items, quests, spells, achievements and recipes.")
		say("Try some with a chat box open and some without.")
		C_Timer.After(120, function()
			capturing = false
			local vias = {}
			for _, c in ipairs(captured) do
				local key = c.via .. (c.chatOpen and " (chat open)" or c.chatOpen == false and " (chat closed)" or "")
				vias[key] = (vias[key] or 0) + 1
			end
			local parts = {}
			for k, n in pairs(vias) do
				parts[#parts + 1] = ("%s x%d"):format(k, n)
			end
			session.capture = #parts > 0 and table.concat(parts, ", ") or "nothing captured"
			say("capture finished: %s. Now type /cspike2 links.", session.capture)
		end)
	elseif cmd == "links" then
		start("the link checks", runLinks)
	elseif cmd == "bnet" then
		if args[2] then
			bnetTarget = tonumber(args[2])
			say("BNet target: %s.", tostring(bnetTarget))
		else
			listBnet()
		end
	elseif cmd == "bnetsize" or cmd == "bnetrate" then
		if not bnetTarget then
			say("pick a target first: /cspike2 bnet, then /cspike2 bnet <gameAccountID>.")
		elseif cmd == "bnetsize" then
			start("the BNet size run", bnetSizes)
		else
			start("the BNet rate run", bnetRate, tonumber(args[2]) or 1000)
		end
	elseif cmd == "report" then
		local s = session
		if not (s.limit or s.reach or s.links or s.bnet or s.bnetIn) and db.sessions[#db.sessions - 1] then
			s = db.sessions[#db.sessions - 1] -- after a /reload, show the previous session
		end
		showReport(buildReport(s))
	elseif cmd == "stop" then
		if job then
			say("stopped %s.", job.name)
			job = nil
		end
		reachOff()
	else
		for _, text in ipairs(HELP) do
			say(text)
		end
	end
end
