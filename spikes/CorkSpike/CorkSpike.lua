-- CorkSpike: throwaway Phase 0 spike for Corkboard (docs/spikes/01 and 02).
--
-- It measures the addon-message throttle and logs every SendAddonMessage
-- result code. It calls C_ChatInfo.SendAddonMessage directly, on purpose: the
-- point is to see what the client does with no outbox or ChatThrottleLib in
-- the way. Corkboard itself must never do this (docs/design.md §5.5, §5.6).
--
-- /cspike all runs the whole script (about 6 minutes), then /cspike report
-- opens a copyable Markdown report. See README.md.

local ADDON_NAME = ...

local PREFIX = "CORKSPK1" -- throttle runs
local PREFIX2 = "CORKSPK2" -- per-prefix test and the canary
local PREFIX_CODES = "CORKSPK3" -- result-code cases
local PREFIXES = { [PREFIX] = true, [PREFIX2] = true, [PREFIX_CODES] = true }

local REST = 30 -- seconds of quiet before a run that needs a full budget
local BURST = 40 -- attempts in one frame for a burst
local DRAIN_MAX = 60 -- most attempts in one frame when draining
local CODE_GAP = 1.5 -- seconds between result-code cases
local MAX_SEGMENTS = 400

local now = GetTimePreciseSec or GetTime
local SendAddon = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage

local db -- CorkSpikeDB
local session -- this login's results; also stored in db.sessions
local runsById = {}
local state = {} -- whisper, channel, bnet targets
local me, myName
local job -- the running script
local canary -- the running canary

-- Output --------------------------------------------------------------------

local function show(v)
	if issecretvalue and issecretvalue(v) then
		return "<secret>"
	end
	if type(v) == "string" then
		return '"' .. (v:gsub("|", "!")) .. '"'
	end
	return tostring(v)
end

local function say(fmt, ...)
	local line = select("#", ...) > 0 and fmt:format(...) or fmt
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd100CorkSpike:|r " .. line)
	if session then
		local log = session.log
		log[#log + 1] = ("%7.2f  %s"):format(now() - session.t0, (line:gsub("|", "!")))
		if #log > 1500 then
			table.remove(log, 1)
		end
	end
end

local function safe(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, a, b = pcall(fn, ...)
	if ok then
		return a, b
	end
end

local function context()
	local instance = select(2, safe(IsInInstance)) or "?"
	return ("combat=%s dead=%s encounter=%s instance=%s"):format(
		show(safe(InCombatLockdown)),
		show(safe(UnitIsDeadOrGhost, "player")),
		show(safe(IsEncounterInProgress)),
		show(instance)
	)
end

-- Result codes ----------------------------------------------------------------

local RESULT = {} -- value -> name, from Enum.SendAddonMessageResult

local function loadResultNames()
	local enum = Enum and Enum.SendAddonMessageResult
	if type(enum) == "table" then
		for name, value in pairs(enum) do
			RESULT[value] = name
		end
	end
end

-- A readable key for everything a pcall'd send returned.
local function resultKey(ok, ...)
	if not ok then
		return "error: " .. (tostring((...)):gsub("|", "!"))
	end
	local n = select("#", ...)
	if n == 0 then
		return "(no return)"
	end
	local parts = {}
	for i = 1, n do
		local v = select(i, ...)
		if type(v) == "number" and RESULT[v] then
			parts[i] = ("%s(%d)"):format(RESULT[v], v)
		else
			parts[i] = show(v)
		end
	end
	return table.concat(parts, ", ")
end

-- Whether the send was accepted. A client that returns nothing counts as
-- accepted here; the report's Received column is the check on that.
local function accepted(ok, ...)
	if not ok then
		return false
	end
	if select("#", ...) == 0 then
		return true
	end
	local first = ...
	if first == true then
		return true
	end
	if type(first) == "number" then
		if RESULT[first] then
			return RESULT[first] == "Success"
		end
		return first == 0
	end
	return false
end

local function rawSend(prefix, text, chatType, target)
	if chatType == "BNET" then
		return pcall(BNSendGameData, target, prefix, text)
	end
	return pcall(SendAddon, prefix, text, chatType, target)
end

local function targetFor(chatType)
	if chatType == "WHISPER" then
		return state.whisper or me
	elseif chatType == "CHANNEL" then
		return state.channel and tostring(state.channel.id)
	elseif chatType == "BNET" then
		return state.bnet
	end
end

-- Whether our own sends on this chat type come back to us.
local function loopback(chatType)
	if chatType == "WHISPER" then
		return not state.whisper
	end
	return chatType ~= "BNET"
end

-- Runs ------------------------------------------------------------------------

local function newRun(kind, chatType, prefix, size, note)
	session.nextId = session.nextId + 1
	local run = {
		id = "r" .. session.nextId,
		kind = kind,
		chatType = chatType,
		prefix = prefix,
		size = size,
		note = note,
		loopback = loopback(chatType),
		start = now() - session.t0,
		t0 = now(),
		attempts = 0,
		okCount = 0,
		lastT = 0,
		codes = {},
		segments = {},
		okTimes = {},
		sent = {},
		recv = {},
	}
	session.runs[#session.runs + 1] = run
	runsById[run.id] = run
	return run
end

local function payload(runId, seq, size)
	local head = runId .. ":" .. seq .. ":"
	if size > #head then
		return head .. ("x"):rep(size - #head)
	end
	return head
end

local function record(run, seq, t, ok, ...)
	local key = resultKey(ok, ...)
	local good = accepted(ok, ...)
	local dt = t - run.t0
	run.lastT = dt
	run.codes[key] = (run.codes[key] or 0) + 1
	local segments = run.segments
	local last = segments[#segments]
	if last and last.key == key then
		last.n = last.n + 1
		last.t2 = dt
	elseif #segments < MAX_SEGMENTS then
		segments[#segments + 1] = { key = key, ok = good, n = 1, t1 = dt, t2 = dt }
	else
		run.truncated = true
	end
	if good then
		run.okCount = run.okCount + 1
		run.okTimes[#run.okTimes + 1] = dt
		run.sent[seq] = t
	end
	return good, key
end

local function attempt(run)
	run.attempts = run.attempts + 1
	local seq = run.attempts
	local t = now()
	return record(run, seq, t, rawSend(run.prefix, payload(run.id, seq, run.size), run.chatType, targetFor(run.chatType)))
end

-- Our own "Name-Realm". Looked up before each script, because the realm can
-- still be missing right at login.
local function refreshMe()
	local name, realm = UnitFullName("player")
	realm = realm or safe(GetNormalizedRealmName)
	myName = name
	me = realm and realm ~= "" and (name .. "-" .. realm) or name
end

-- Script runner -------------------------------------------------------------------

local function wait(seconds)
	job.wake = now() + seconds
	coroutine.yield()
end

local function nextFrame()
	job.wake = 0
	coroutine.yield()
end

local function rest(why)
	say("quiet for %d s (%s)", REST, why)
	wait(REST)
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
		say("%s finished. Type /cspike report to see the results.", current.name)
		job = nil
	end
end)

local function start(name, fn, ...)
	if job then
		say("still running %s; /cspike stop first.", job.name)
		return
	end
	if canary then
		say("the canary is on; /cspike canary off first.")
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

-- Measurements ------------------------------------------------------------------

local function burst(chatType, n, size, prefix, kind, note)
	local run = newRun(kind or "burst", chatType, prefix or PREFIX, size or 16, note)
	for _ = 1, n or BURST do
		attempt(run)
	end
	say("%s %s: %d of %d accepted in one frame.", run.id, chatType, run.okCount, run.attempts)
	return run
end

-- Sends in one frame until the first rejection (and 5 more), so the budget
-- is empty.
local function drain(chatType, prefix)
	local run = newRun("drain", chatType, prefix or PREFIX, 16)
	local rejected = 0
	while run.attempts < DRAIN_MAX and rejected < 6 do
		if not attempt(run) then
			rejected = rejected + 1
		end
	end
	if rejected == 0 then
		say("%s: %d sends in one frame were all accepted, so the drain failed.", run.id, run.attempts)
	end
	return run
end

-- One send attempt per frame for `seconds`. Starting from an empty budget, the
-- accepted sends show the sustained rate.
local function rate(chatType, seconds, size)
	local run = newRun("rate", chatType, PREFIX, size or 16, ("%d s, one attempt per frame"):format(seconds))
	local stop = now() + seconds
	while now() < stop do
		attempt(run)
		nextFrame()
	end
	say("%s %s %d B: %d of %d attempts accepted over %d s.", run.id, chatType, run.size, run.okCount, run.attempts,
		seconds)
	return run
end

local function refill(chatType, waits)
	drain(chatType)
	for _, seconds in ipairs(waits) do
		wait(seconds)
		burst(chatType, BURST, 16, PREFIX, "refill", ("after %d s"):format(seconds))
	end
end

-- Empties one budget, then tries another prefix or chat type right away.
-- Accepted there means the budgets are separate.
local function crossCheck(kind, fromType, toType, toPrefix)
	local from = drain(fromType, PREFIX)
	local note = ("right after draining %s on %s (%s)"):format(PREFIX, fromType, from.id)
	return burst(toType, 3, 16, toPrefix, kind, note)
end

local function prefixTest(chatType)
	rest("full budget")
	crossCheck("prefix", chatType, chatType, PREFIX2)
end

local function shareTest(fromType, toType)
	rest("full budget")
	crossCheck("share", fromType, toType, PREFIX)
end

-- API probe (spike 01) ------------------------------------------------------------

local WORDS = { "restrict", "lockdown", "secret" }

local function interesting(name)
	name = name:lower()
	for _, word in ipairs(WORDS) do
		if name:find(word, 1, true) then
			return true
		end
	end
	return false
end

local function resolve(path)
	local ns, key = path:match("^([%w_]+)%.([%w_]+)$")
	if ns then
		return type(_G[ns]) == "table" and _G[ns][key] or nil
	end
	return _G[path]
end

local function callShow(fn)
	local results = { pcall(fn) }
	if not results[1] then
		return "error: " .. (tostring(results[2]):gsub("|", "!"))
	end
	local parts = {}
	for i = 2, table.maxn(results) do
		parts[#parts + 1] = show(results[i])
	end
	return #parts > 0 and table.concat(parts, ", ") or "(no return)"
end

local function enumText(enum)
	local pairsList = {}
	for name, value in pairs(enum) do
		pairsList[#pairsList + 1] = { name = name, value = value }
	end
	table.sort(pairsList, function(a, b)
		if type(a.value) == type(b.value) and type(a.value) == "number" then
			return a.value < b.value
		end
		return tostring(a.name) < tostring(b.name)
	end)
	local out = {}
	for i, p in ipairs(pairsList) do
		out[i] = ("%s=%s"):format(tostring(p.name), tostring(p.value))
	end
	return table.concat(out, ", ")
end

local function probe()
	local p = { candidates = {}, chatInfo = {}, enums = {}, projects = {} }
	local ok, version, build, buildDate, toc = pcall(GetBuildInfo)
	p.build = ok and ("%s (build %s, %s), TOC %s"):format(tostring(version), tostring(build), tostring(buildDate),
		tostring(toc)) or "?"
	p.realm = safe(GetRealmName) or "?"
	p.issecretvalue = type(issecretvalue) == "function"
	p.bnSendGameData = type(BNSendGameData) == "function"
	p.sendAddonMessage = C_ChatInfo and C_ChatInfo.SendAddonMessage and "C_ChatInfo.SendAddonMessage"
		or (SendAddonMessage and "SendAddonMessage (global)")
		or "missing"

	local found = {}
	for name, value in pairs(_G) do
		if type(name) == "string" then
			if type(value) == "function" and interesting(name) then
				found[#found + 1] = name
			elseif type(value) == "table" and name:find("^C_") then
				pcall(function()
					for key, fn in pairs(value) do
						if type(key) == "string" and type(fn) == "function" then
							if interesting(name) or interesting(key) then
								found[#found + 1] = name .. "." .. key
							end
							if name == "C_ChatInfo" then
								p.chatInfo[#p.chatInfo + 1] = key
							end
						end
					end
				end)
			elseif name:find("^WOW_PROJECT_") then
				p.projects[#p.projects + 1] = ("%s=%s"):format(name, tostring(value))
			end
		end
	end
	table.sort(found)
	table.sort(p.chatInfo)
	table.sort(p.projects)
	for _, name in ipairs(found) do
		local short = name:match("([%w_]+)$")
		-- Only zero-argument queries: Is/Are/In/Has/Get/Can followed by a capital.
		local pollable = short:find("^Is%u") or short:find("^Are%u") or short:find("^In%u") or short:find("^Has%u")
			or short:find("^Get%u") or short:find("^Can%u")
		p.candidates[#p.candidates + 1] = {
			name = name,
			value = pollable and callShow(resolve(name)) or "(not called)",
			pollable = pollable and true or false,
		}
	end
	if type(Enum) == "table" then
		for name, enum in pairs(Enum) do
			if type(enum) == "table" and (interesting(name) or name:find("AddonMessage")
				or name:find("AddOnMessage") or name:find("ChatMessaging")) then
				p.enums[name] = enumText(enum)
			end
		end
	end
	session.probe = p
	say("client %s, SendAddonMessage is %s, issecretvalue %s.", p.build, p.sendAddonMessage,
		p.issecretvalue and "exists" or "missing")
	for _, c in ipairs(p.candidates) do
		say("  %s = %s", c.name, c.value)
	end
	for name, text in pairs(p.enums) do
		say("  Enum.%s: %s", name, text)
	end
	return p
end

-- Result codes (spike 01) --------------------------------------------------------

local codes -- the running codes test

local function codeCases()
	local realm = safe(GetNormalizedRealmName) or "Realm"
	return {
		{ "WHISPER to self", PREFIX_CODES, "ok", "WHISPER", "self" },
		{ "lower-case chat type", PREFIX_CODES, "ok", "whisper", "self" },
		{ "WHISPER without a target", PREFIX_CODES, "x", "WHISPER", nil },
		{ "WHISPER to a player who doesn't exist", PREFIX_CODES, "x", "WHISPER", "Nobodyqzxw-" .. realm },
		{ "17-character prefix", "CORKSPIKE17CHARSX", "x", "WHISPER", "self" },
		{ "empty prefix", "", "x", "WHISPER", "self" },
		{ "unregistered prefix", "CORKSPKNOREG", "x", "WHISPER", "self" },
		{ "empty message", PREFIX_CODES, "", "WHISPER", "self" },
		{ "255-byte message", PREFIX_CODES, ("x"):rep(255), "WHISPER", "self" },
		{ "256-byte message", PREFIX_CODES, ("x"):rep(256), "WHISPER", "self" },
		{ "4000-byte message", PREFIX_CODES, ("x"):rep(4000), "WHISPER", "self" },
		{ "message with a NUL byte", PREFIX_CODES, "a\0b", "WHISPER", "self" },
		{ "message with a newline", PREFIX_CODES, "a\nb", "WHISPER", "self" },
		{ "message with a pipe", PREFIX_CODES, "a|b", "WHISPER", "self" },
		{ "message with byte 0xFF", PREFIX_CODES, "a\255b", "WHISPER", "self" },
		{ "message holding an item link", PREFIX_CODES,
			"|cffffffff|Hitem:6948::::::::1:::::::::|h[Hearthstone]|h|r", "WHISPER", "self" },
		{ "unknown chat type", PREFIX_CODES, "x", "BOGUS", nil },
		{ "SAY", PREFIX_CODES, "x", "SAY", nil },
		{ "YELL", PREFIX_CODES, "x", "YELL", nil },
		{ "PARTY", PREFIX_CODES, "x", "PARTY", nil },
		{ "RAID", PREFIX_CODES, "x", "RAID", nil },
		{ "INSTANCE_CHAT", PREFIX_CODES, "x", "INSTANCE_CHAT", nil },
		{ "GUILD", PREFIX_CODES, "x", "GUILD", nil },
		{ "OFFICER", PREFIX_CODES, "x", "OFFICER", nil },
		{ "CHANNEL 99 (not joined)", PREFIX_CODES, "x", "CHANNEL", "99" },
		{ "CHANNEL by name", PREFIX_CODES, "x", "CHANNEL", "General" },
	}
end

local function runCodes()
	codes = { cases = {} }
	session.codes = codes
	session.codes.inGroup = safe(IsInGroup) and true or false
	session.codes.inGuild = safe(IsInGuild) and true or false
	for _, spec in ipairs(codeCases()) do
		local label, prefix, text, chatType, target = unpack(spec, 1, 5)
		local case = { label = label, chatType = chatType, bytes = #text }
		codes.cases[#codes.cases + 1] = case
		codes.current = case
		codes.text = text
		case.result = resultKey(pcall(SendAddon, prefix, text, chatType, target == "self" and me or target))
		say("%s: %s", label, case.result)
		wait(CODE_GAP)
	end
	codes.current = nil
end

local function codesArrival(text)
	local case = codes and codes.current
	if not case then
		return
	end
	if text == codes.text then
		case.arrived = "intact"
	else
		local at = 1
		while at <= #text and text:byte(at) == codes.text:byte(at) do
			at = at + 1
		end
		case.arrived = ("changed: %d bytes, first difference at byte %d"):format(#text, at)
	end
end

-- Canary (spike 01) ------------------------------------------------------------------

local watchFrame = CreateFrame("Frame")

local function canaryStop()
	if not canary then
		return
	end
	canary.ticker:Cancel()
	pcall(watchFrame.UnregisterAllEvents, watchFrame)
	canary = nil
	say("canary off.")
end

local function canaryTick()
	for _, watch in ipairs(canary.watches) do
		local fn = watch.fn or resolve(watch.name)
		local value = type(fn) == "function" and callShow(fn) or "(missing)"
		if value ~= watch.last then
			say("%s: %s -> %s [%s]", watch.name, tostring(watch.last), value, context())
			watch.last = value
		end
	end
	local ctx = context()
	if ctx ~= canary.lastContext then
		say("context: %s", ctx)
		canary.lastContext = ctx
	end
	canary.ticks = canary.ticks + 1
	if canary.ticks % 2 == 0 then
		local _, key = attempt(canary.run)
		if key ~= canary.lastKey then
			say("canary send: %s -> %s [%s]", tostring(canary.lastKey), key, ctx)
			canary.lastKey = key
		end
	end
end

local function canaryStart()
	if job then
		say("still running %s; /cspike stop first.", job.name)
		return
	end
	if canary then
		return
	end
	refreshMe()
	local p = session.probe or probe()
	canary = { watches = {}, ticks = 0, run = newRun("canary", "WHISPER", PREFIX2, 16, "one send every 2 s") }
	for _, c in ipairs(p.candidates) do
		if c.pollable then
			canary.watches[#canary.watches + 1] = { name = c.name }
		end
	end
	for _, expr in ipairs(state.watches or {}) do
		canary.watches[#canary.watches + 1] = expr
	end
	-- Log any event whose name looks like a restriction change.
	pcall(watchFrame.RegisterAllEvents, watchFrame)
	canary.ticker = C_Timer.NewTicker(1, canaryTick)
	say("canary on: polling %d functions every second and sending every 2 s. Pull a boss, die, release, resurrect.",
		#canary.watches)
end

local seenEvents = {}
watchFrame:SetScript("OnEvent", function(_, event, ...)
	if seenEvents[event] == nil then
		seenEvents[event] = interesting(event)
	end
	if seenEvents[event] then
		local args = {}
		for i = 1, math.min(select("#", ...), 4) do
			args[i] = show((select(i, ...)))
		end
		say("event %s(%s) [%s]", event, table.concat(args, ", "), context())
	end
end)

-- Channel and BNet targets ------------------------------------------------------------

local function joinChannel(name)
	name = name or ("CorkSpike" .. math.random(10000, 99999))
	local password = "cs" .. math.random(100000, 999999)
	safe(JoinTemporaryChannel, name, password)
	for _ = 1, 25 do
		local id = safe(GetChannelName, name)
		if id and id > 0 then
			state.channel = { name = name, id = id }
			for i = 1, (NUM_CHAT_WINDOWS or 10) do
				local frame = _G["ChatFrame" .. i]
				if frame and ChatFrame_RemoveChannel then
					pcall(ChatFrame_RemoveChannel, frame, name)
				end
			end
			say("joined channel %s (id %d).", name, id)
			return id
		end
		wait(0.2)
	end
	say("couldn't join channel %s; CHANNEL runs are skipped.", name)
end

local function leaveChannel()
	if state.channel then
		safe(LeaveChannelByName, state.channel.name)
		say("left channel %s.", state.channel.name)
		state.channel = nil
	end
end

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
	else
		say("type /cspike bnet <gameAccountID> to target one (they should run CorkSpike too).")
	end
end

-- The full script -------------------------------------------------------------------------

local function runAll()
	session.all = true
	probe()
	runCodes()
	if not state.channel then
		joinChannel()
	end

	rest("full budget before the first burst")
	burst("WHISPER", BURST, 16)
	rate("WHISPER", 45, 16)
	refill("WHISPER", { 3, 6, 12 })

	prefixTest("WHISPER")
	local others = {}
	if state.channel then
		others[#others + 1] = "CHANNEL"
	end
	if safe(IsInGuild) then
		others[#others + 1] = "GUILD"
	end
	if safe(IsInGroup) then
		others[#others + 1] = "PARTY"
	end
	if state.bnet then
		others[#others + 1] = "BNET"
	end
	for _, chatType in ipairs(others) do
		shareTest("WHISPER", chatType)
	end
	if state.channel then
		rest("full budget")
		burst("CHANNEL", BURST, 16)
	end

	rest("full budget")
	rate("WHISPER", 45, 255)
	wait(5) -- let the last loopback messages arrive
	leaveChannel()
end

-- Report --------------------------------------------------------------------------------

local function median(list)
	if #list == 0 then
		return nil
	end
	local sorted = {}
	for i, v in ipairs(list) do
		sorted[i] = v
	end
	table.sort(sorted)
	return sorted[math.ceil(#sorted / 2)]
end

local function ms(seconds)
	return seconds and ("%d"):format(seconds * 1000 + 0.5) or "-"
end

local function segmentsText(run, limit)
	local out = {}
	for i, seg in ipairs(run.segments) do
		if i > limit then
			out[#out + 1] = ("... %d more"):format(#run.segments - limit)
			break
		end
		out[#out + 1] = ("%s x%d"):format(seg.key, seg.n)
	end
	return table.concat(out, " -> ")
end

local function received(run)
	local seen, unique, dup, latencies, reordered, highest = {}, 0, 0, {}, 0, 0
	for _, r in ipairs(run.recv) do
		if seen[r.seq] then
			dup = dup + 1
		else
			seen[r.seq] = true
			unique = unique + 1
			if r.lat then
				latencies[#latencies + 1] = r.lat
			end
		end
		if r.seq < highest then
			reordered = reordered + 1
		end
		highest = math.max(highest, r.seq)
	end
	return unique, dup, latencies, reordered
end

local function analyse(run)
	local a = { burst = 0 }
	local firstReject
	for _, seg in ipairs(run.segments) do
		if not seg.ok then
			firstReject = seg.t1
			break
		end
		a.burst = a.burst + seg.n
	end
	a.firstReject = firstReject
	if firstReject then
		local after = {}
		for _, t in ipairs(run.okTimes) do
			if t > firstReject then
				after[#after + 1] = t
			end
		end
		local gaps = {}
		for i = 2, #after do
			gaps[#gaps + 1] = after[i] - after[i - 1]
		end
		local span = run.lastT - firstReject
		a.after = #after
		a.span = span
		a.rate = span > 0 and #after / span or nil
		a.gap = median(gaps)
	end
	a.unique, a.dup, a.latencies, a.reordered = received(run)
	table.sort(a.latencies)
	return a
end

local function buildReport(s)
	local out = {}
	local function line(fmt, ...)
		out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
	end
	local p = s.probe or {}

	line("## CorkSpike report")
	line("")
	line("- Run at: %s (local time)", s.date or "?")
	line("- Client: %s", p.build or "?")
	line("- Realm: %s", p.realm or "?")
	line("- Other addons loaded: %s", s.addons or "?")
	line("- Whisper target: %s. BNet target: %s.", s.whisperTarget or "self", s.bnetTarget or "none")

	line("")
	line("### Spike 01: restriction API and result codes")
	line("")
	line("- Send function: `%s`. `issecretvalue`: %s. `BNSendGameData`: %s.", p.sendAddonMessage or "?",
		p.issecretvalue and "present" or "missing", p.bnSendGameData and "present" or "missing")
	line("- `C_ChatInfo`: %s", p.chatInfo and table.concat(p.chatInfo, ", ") or "?")
	line("- `WOW_PROJECT_*`: %s", p.projects and table.concat(p.projects, ", ") or "?")
	line("- Functions whose names mention restrict, lockdown or secret (value when idle):")
	for _, c in ipairs(p.candidates or {}) do
		line("  - `%s` = %s", c.name, c.value)
	end
	for name, text in pairs(p.enums or {}) do
		line("- `Enum.%s`: %s", name, text)
	end
	if s.codes then
		line("")
		line("In a group: %s. In a guild: %s.", tostring(s.codes.inGroup), tostring(s.codes.inGuild))
		line("")
		line("| Case | Chat type | Bytes | Result | Arrived |")
		line("|---|---|---|---|---|")
		for _, case in ipairs(s.codes.cases) do
			line("| %s | %s | %d | %s | %s |", case.label, tostring(case.chatType), case.bytes, case.result,
				case.arrived or (case.chatType:upper() == "WHISPER" and "no" or "-"))
		end
		if s.codes.system and #s.codes.system > 0 then
			line("")
			line("System messages during the cases:")
			for _, text in ipairs(s.codes.system) do
				line("- %s", text)
			end
		end
	end
	if s.secret and s.secret > 0 then
		line("")
		line("Secret payloads received and dropped: %d.", s.secret)
	end

	line("")
	line("### Spike 02: throttle")
	line("")
	line("| Run | Kind | Chat type | Prefix | Bytes | Attempts | Accepted | Received | Latency ms (min/med/max) | Notes |")
	line("|---|---|---|---|---|---|---|---|---|---|")
	for _, run in ipairs(s.runs) do
		local a = analyse(run)
		local recv = run.loopback and ("%d%s"):format(a.unique, a.dup > 0 and (" (+%d dup)"):format(a.dup) or "")
			or "n/a"
		line("| %s | %s | %s | %s | %d | %d | %d | %s | %s/%s/%s | %s |", run.id, run.kind, run.chatType, run.prefix,
			run.size, run.attempts, run.okCount, recv, ms(a.latencies[1]), ms(median(a.latencies)),
			ms(a.latencies[#a.latencies]), run.note or "")
	end
	line("")
	line("Per run (times in seconds from the run's first attempt):")
	line("")
	for _, run in ipairs(s.runs) do
		local a = analyse(run)
		line("- **%s %s %s %d B**: %s", run.id, run.kind, run.chatType, run.size, segmentsText(run, 12))
		if a.firstReject then
			line("  - %d accepted before the first rejection at %.2f s.", a.burst, a.firstReject)
			if run.kind == "rate" and a.rate then
				line("  - After that: %d accepted in %.1f s = **%.2f msg/s**; median gap %.2f s.", a.after, a.span,
					a.rate, a.gap or 0)
				local times = {}
				for i, t in ipairs(run.okTimes) do
					if i > 80 then
						times[#times + 1] = "..."
						break
					end
					times[#times + 1] = ("%.2f"):format(t)
				end
				line("  - Accepted at: %s", table.concat(times, " "))
			end
		elseif run.attempts > 0 then
			line("  - No rejections.")
		end
		if run.loopback and run.okCount > 0 then
			line("  - Received %d of %d accepted%s%s.", a.unique, run.okCount,
				a.dup > 0 and (", %d duplicates"):format(a.dup) or "",
				a.reordered > 0 and (", %d out of order"):format(a.reordered) or "")
		end
		if run.truncated then
			line("  - (segment list truncated)")
		end
	end

	local foreign = {}
	for key, f in pairs(s.foreign or {}) do
		foreign[#foreign + 1] = ("- %s: %d messages, up to %d bytes, first %.1f s, last %.1f s"):format(key, f.n,
			f.maxBytes, f.first, f.last)
	end
	if #foreign > 0 then
		table.sort(foreign)
		line("")
		line("### Arrivals from other characters")
		line("")
		for _, text in ipairs(foreign) do
			line(text)
		end
	end

	line("")
	line("### Log")
	line("")
	line("```")
	local log = s.log
	for i = math.max(1, #log - 400), #log do
		line(log[i])
	end
	line("```")
	return table.concat(out, "\n")
end

local reportFrame

local function showReport(text)
	if not reportFrame then
		local f = CreateFrame("Frame", "CorkSpikeReportFrame", UIParent, "BasicFrameTemplateWithInset")
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
		title:SetText("CorkSpike report: the text is selected, press Ctrl+C to copy")
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
		table.insert(UISpecialFrames, "CorkSpikeReportFrame")
		reportFrame = f
	end
	reportFrame:Show()
	reportFrame.edit:SetText(text)
	reportFrame.edit:SetFocus()
	reportFrame.edit:HighlightText()
end

-- Receiving ------------------------------------------------------------------------------

local peers = {}

local function isSelf(sender)
	return sender == me or sender == myName
end

local function who(sender)
	if isSelf(sender) then
		return "self"
	end
	if not peers[sender] then
		peers.n = (peers.n or 0) + 1
		peers[sender] = "peer" .. peers.n
	end
	return peers[sender]
end

local function onAddonMessage(prefix, text, channel, sender)
	if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(sender)) then
		session.secret = (session.secret or 0) + 1
		return
	end
	if not PREFIXES[prefix] then
		return
	end
	local t = now()
	if prefix == PREFIX_CODES and isSelf(sender) then
		codesArrival(text)
		return
	end
	local id, seq = text:match("^(r%d+):(%d+):")
	local run = id and runsById[id]
	if run and isSelf(sender) then
		seq = tonumber(seq)
		local sent = run.sent[seq]
		run.recv[#run.recv + 1] = { seq = seq, lat = sent and t - sent, channel = channel }
		return
	end
	local key = ("%s %s %s %s"):format(who(sender), tostring(channel), prefix, id or "?")
	local f = session.foreign[key] or { n = 0, maxBytes = 0, first = t - session.t0 }
	session.foreign[key] = f
	f.n = f.n + 1
	f.maxBytes = math.max(f.maxBytes, #text)
	f.last = t - session.t0
end

-- Setup -----------------------------------------------------------------------------------

local function addonList()
	local names = {}
	local numAddOns = C_AddOns and C_AddOns.GetNumAddOns or GetNumAddOns
	local getInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	for i = 1, safe(numAddOns) or 0 do
		local name = safe(getInfo, i)
		if name and name ~= ADDON_NAME and safe(isLoaded, i) then
			names[#names + 1] = name
		end
	end
	return #names > 0 and table.concat(names, ", ") or "none"
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, event in ipairs({
	"CHAT_MSG_ADDON", "BN_CHAT_MSG_ADDON", "CHAT_MSG_SYSTEM", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
	"ENCOUNTER_START", "ENCOUNTER_END", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
}) do
	pcall(events.RegisterEvent, events, event)
end

events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON_NAME then
			CorkSpikeDB = CorkSpikeDB or {}
			db = CorkSpikeDB
			db.sessions = db.sessions or {}
			while #db.sessions >= 5 do
				table.remove(db.sessions, 1)
			end
			session = { t0 = now(), nextId = 0, runs = {}, log = {}, foreign = {}, date = date("%Y-%m-%d %H:%M") }
			db.sessions[#db.sessions + 1] = session
		end
	elseif event == "PLAYER_LOGIN" then
		loadResultNames()
		for prefix in pairs(PREFIXES) do
			local result = resultKey(pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix))
			session.log[#session.log + 1] = ("register %s: %s"):format(prefix, result)
		end
		session.addons = addonList()
	elseif event == "CHAT_MSG_ADDON" then
		onAddonMessage(...)
	elseif event == "BN_CHAT_MSG_ADDON" then
		local prefix, text, _, senderID = ...
		onAddonMessage(prefix, text, "BNET", "bnet:" .. tostring(senderID))
	elseif event == "CHAT_MSG_SYSTEM" then
		if codes and codes.current then
			local text = tostring((...)):gsub("|", "!")
			if myName then
				text = text:gsub(myName, "<self>")
			end
			codes.system = codes.system or {}
			table.insert(codes.system, ("%s: %s"):format(codes.current.label, text))
		end
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		local addon, action = ...
		if addon == ADDON_NAME or canary then
			say("%s: %s %s [%s]", event, show(addon), show(action), context())
		end
	elseif canary then
		say("event %s [%s]", event, context())
	end
end)

-- Slash command ------------------------------------------------------------------------------

local HELP = {
	"/cspike all: the whole script, about 6 minutes. Stand still somewhere quiet.",
	"/cspike report: open the copyable report (Ctrl+C).",
	"/cspike canary on|off: poll the restriction check and send every 2 s. Then pull a boss or die.",
	"/cspike probe | codes: just the API probe, or just the result-code cases.",
	"/cspike burst|rate|refill|prefix [TYPE]: single measurements. share <FROM> <TO>.",
	"/cspike channel [name]: join a temporary channel for CHANNEL runs.",
	"/cspike target Name-Realm|self: whisper target. bnet [gameAccountID]: list or set a BNet target.",
	"/cspike watch <lua expression>: add an expression for the canary to poll.",
	"/cspike stop: abort. TYPE is WHISPER, CHANNEL, GUILD, PARTY, RAID or BNET.",
}

SLASH_CORKSPIKE1 = "/cspike"
SlashCmdList.CORKSPIKE = function(input)
	local args = {}
	for word in input:gmatch("%S+") do
		args[#args + 1] = word
	end
	local cmd = (args[1] or "help"):lower()
	local chatType = (args[2] or "WHISPER"):upper()

	refreshMe()
	if cmd == "all" then
		start("the full script", runAll)
	elseif cmd == "report" then
		local s = session
		if #s.runs == 0 and not s.codes and not s.probe then
			s = db.sessions[#db.sessions - 1] or s -- after a /reload, show the previous session
		end
		showReport(buildReport(s))
	elseif cmd == "probe" then
		probe()
	elseif cmd == "codes" then
		start("the result-code cases", runCodes)
	elseif cmd == "burst" then
		start("burst", burst, chatType, tonumber(args[3]) or BURST, tonumber(args[4]) or 16)
	elseif cmd == "rate" then
		start("rate", rate, chatType, tonumber(args[3]) or 45, tonumber(args[4]) or 16)
	elseif cmd == "refill" then
		start("refill", refill, chatType, { 3, 6, 12 })
	elseif cmd == "prefix" then
		start("prefix", prefixTest, chatType)
	elseif cmd == "share" and args[3] then
		start("share", shareTest, chatType, args[3]:upper())
	elseif cmd == "canary" then
		if (args[2] or "on"):lower() == "off" then
			canaryStop()
		else
			canaryStart()
		end
	elseif cmd == "channel" then
		start("channel join", joinChannel, args[2])
	elseif cmd == "target" and args[2] then
		state.whisper = args[2]:lower() ~= "self" and args[2] or nil
		session.whisperTarget = state.whisper and "another character" or "self"
		say("whisper target: %s.", state.whisper or "self")
	elseif cmd == "bnet" then
		if args[2] then
			state.bnet = tonumber(args[2])
			session.bnetTarget = state.bnet and "a BNet friend" or nil
			say("BNet target: %s.", tostring(state.bnet))
		else
			listBnet()
		end
	elseif cmd == "watch" and args[2] then
		local expr = input:match("^%S+%s+(.+)$")
		local fn, err = loadstring("return " .. expr)
		if fn then
			state.watches = state.watches or {}
			table.insert(state.watches, { name = expr, fn = fn })
			say("watching %s (value now: %s).", expr, callShow(fn))
		else
			say("can't compile that: %s", tostring(err))
		end
	elseif cmd == "stop" then
		if job then
			say("stopped %s.", job.name)
			job = nil
		end
		canaryStop()
		leaveChannel()
	else
		for _, text in ipairs(HELP) do
			say(text)
		end
	end
end
