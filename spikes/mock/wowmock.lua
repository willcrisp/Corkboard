-- Minimal fake WoW client for smoke-testing spikes/CorkSpike outside the game.
-- Not a faithful model: a per-prefix token bucket (burst 10, 1/s), loopback
-- delivery, and a toggleable lockdown.
local T = 1000
local timers, deliveries, frames, chat = {}, {}, {}, {}
local mock = { locked = false, chat = chat }

local function obj()
	local o
	o = setmetatable({}, {
		__call = function() return nil end,
		__index = function(t, k)
			local child = obj()
			rawset(t, k, child)
			return child
		end,
	})
	return o
end

local Frame = {}
Frame.__index = function(t, k)
	if Frame[k] then return Frame[k] end
	local child = obj()
	rawset(t, k, child)
	return child
end
function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:RegisterEvent(ev) self.events[ev] = true end
function Frame:RegisterAllEvents() self.all = true end
function Frame:UnregisterAllEvents() self.events = {}; self.all = false end
function Frame:SetText(text) self.text = text end
function Frame.CreateFontString() return setmetatable({ scripts = {}, events = {} }, Frame) end

_G.CreateFrame = function(kind, name, _, template)
	local f = setmetatable({ scripts = {}, events = {}, kind = kind, template = template }, Frame)
	frames[#frames + 1] = f
	if name then _G[name] = f end
	return f
end

local function fire(event, ...)
	for _, f in ipairs(frames) do
		if (f.events[event] or f.all) and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end
mock.fire = fire

_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) chat[#chat + 1] = msg; if mock.echo then print(msg) end end }
_G.GetTimePreciseSec = function() return T end
_G.GetTime = function() return T end
_G.C_Timer = {
	After = function(s, fn) timers[#timers + 1] = { at = T + s, fn = fn } end,
	NewTicker = function(s, fn)
		local ticker = { cancelled = false }
		function ticker:Cancel() self.cancelled = true end
		local function arm()
			timers[#timers + 1] = { at = T + s, fn = function() if not ticker.cancelled then fn(); arm() end end }
		end
		arm()
		return ticker
	end,
}

_G.Enum = {
	SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
		InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
		GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11 },
	RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
	ChatMessagingLockdownReason = { None = 0, Encounter = 1, Death = 2 },
}
local R = _G.Enum.SendAddonMessageResult
local registered, buckets = {}, {}
local ME, NAME = "Tester-MockRealm", "Tester"
local CHAT_TYPES = { WHISPER = true, PARTY = true, RAID = true, GUILD = true, OFFICER = true, CHANNEL = true,
	INSTANCE_CHAT = true, SAY = true, YELL = true }

local function take(prefix)
	local b = buckets[prefix] or { tokens = 10, at = T }
	buckets[prefix] = b
	b.tokens = math.min(10, b.tokens + (T - b.at))
	b.at = T
	if b.tokens >= 1 then b.tokens = b.tokens - 1; return true end
	return false
end

_G.C_ChatInfo = {
	RegisterAddonMessagePrefix = function(p) registered[p] = true; return 0 end,
	IsAddonMessagePrefixRegistered = function(p) return registered[p] or false end,
	InChatMessagingLockdown = function() return mock.locked, mock.locked and 1 or 0 end,
	SendAddonMessage = function(prefix, text, chatType, target)
		if type(prefix) ~= "string" or #prefix == 0 or #prefix > 16 then return R.InvalidPrefix end
		if #text > 255 or text:find("\0", 1, true) then return R.InvalidMessage end
		if not CHAT_TYPES[chatType] then return R.InvalidChatType end
		if chatType == "WHISPER" and not target then return R.TargetRequired end
		if (chatType == "PARTY" or chatType == "RAID" or chatType == "INSTANCE_CHAT") then return R.NotInGroup end
		if chatType == "CHANNEL" and target ~= "5" then return R.InvalidChannel end
		if chatType == "SAY" or chatType == "YELL" then error("SendAddonMessage: SAY is not allowed") end
		if mock.locked then return R.AddOnMessageLockdown end
		if not take(prefix) then return R.AddonMessageThrottle end
		local back = (chatType == "WHISPER" and (target == ME or target == NAME or target == NAME .. "-MockRealm"))
			or chatType == "CHANNEL"
			or chatType == "GUILD"
		if back and registered[prefix] then
			deliveries[#deliveries + 1] = { at = T + 0.05 + (#text / 10000), args = { prefix, text, chatType, ME } }
		end
		return R.Success
	end,
}
_G.C_RestrictedActions = { IsAddOnRestrictionActive = function(kind) assert(kind, "kind required"); return false end }
_G.UnitFullName = function() return NAME, nil end -- realm missing, like early login
_G.GetNormalizedRealmName = function() return "MockRealm" end
_G.GetRealmName = function() return "Mock Realm" end
_G.GetBuildInfo = function() return "1.60.0", "99999", "Sep 20 2026", 16001 end
_G.IsInGuild = function() return true end
_G.IsInGroup = function() return false end
_G.IsInInstance = function() return false, "none" end
_G.InCombatLockdown = function() return mock.locked end
_G.UnitIsDeadOrGhost = function() return false end
_G.IsEncounterInProgress = function() return mock.locked end
_G.issecretvalue = function() return false end
-- Up to mock.channelLimit custom channels, numbered from 5 (1-4 are the zone channels).
mock.channels, mock.channelLimit = {}, 10
_G.JoinTemporaryChannel = function(name)
	if #mock.channels < mock.channelLimit then
		mock.channels[#mock.channels + 1] = name
		mock.channel = name
	end
end
_G.GetChannelName = function(name)
	for i, n in ipairs(mock.channels) do if n == name then return 4 + i, name end end
	return 0
end
_G.LeaveChannelByName = function(name)
	for i, n in ipairs(mock.channels) do if n == name then table.remove(mock.channels, i) break end end
	if mock.channel == name then mock.channel = nil end
end
_G.GetChannelList = function()
	local out = { 1, "General", false, 2, "Trade", false }
	for i, n in ipairs(mock.channels) do out[#out + 1] = 4 + i; out[#out + 1] = n; out[#out + 1] = false end
	return unpack(out)
end
_G.GetChatWindowChannels = function(i) if i == 1 then return "General", 1, "Trade", 2 end end
_G.hooksecurefunc = function(target, name, hook)
	if type(target) == "string" then target, name, hook = _G, target, name end
	local original = target[name]
	target[name] = function(...) local r = { original(...) } hook(...) return unpack(r) end
end
_G.ChatFrameUtil = { InsertLink = function() return false end }
_G.C_Container = {
	GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
	GetContainerItemLink = function(_, slot)
		if slot == 1 then return "|cffffffff|Hitem:6948::::::::1:::::::::|h[Hearthstone]|h|r" end
		return "|cnIQ4:|Hitem:19019::::::::60:::::::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
	end,
}
_G.C_QuestLog = {
	GetNumQuestLogEntries = function() return 1 end,
	GetInfo = function() return { questID = 7, isHeader = false } end,
}
_G.GetQuestLink = function(id) return "|cffffff00|Hquest:" .. id .. ":5|h[Kobold Camp Cleanup]|h|r" end
_G.C_Spell = { GetSpellLink = function(id) return "|cff71d5ff|Hspell:" .. id .. ":0|h[Spell " .. id .. "]|h|r" end }
_G.GameTooltip = { SetOwner = function() end, NumLines = function() return 2 end, Hide = function() end,
	SetHyperlink = function(_, link) assert(link:find("|H[iqs]"), "unknown link type") end }
_G.UnitFactionGroup = function() return "Alliance" end
_G.GetCurrentRegionName = function() return "EU" end
_G.GetCVar = function() return "EU" end
_G.GetLocale = function() return "enUS" end
_G.ChatFrame_RemoveChannel = function() end
_G.NUM_CHAT_WINDOWS = 10
_G.ChatFrame1 = {}
_G.BNGetNumFriends = function() return 0 end
_G.C_BattleNet = {}
_G.C_AddOns = { GetNumAddOns = function() return 2 end,
	GetAddOnInfo = function(i) return i == 1 and "CorkSpike" or "Details" end, IsAddOnLoaded = function() return true end }
_G.SlashCmdList = {}
_G.UISpecialFrames = {}
_G.UIParent = {}
_G.ChatFontNormal = {}
_G.WOW_PROJECT_ID = 99
_G.WOW_PROJECT_MAINLINE = 1
_G.date = os.date

function mock.advance(seconds)
	local stop = T + seconds
	while T < stop do
		T = T + 1 / 60
		for i = #timers, 1, -1 do
			local t = timers[i]
			if t.at <= T then table.remove(timers, i); t.fn() end
		end
		local due, keep = {}, {}
		for _, d in ipairs(deliveries) do
			if d.at <= T then due[#due + 1] = d else keep[#keep + 1] = d end
		end
		deliveries = keep
		for _, d in ipairs(due) do fire("CHAT_MSG_ADDON", unpack(d.args)) end
		for _, f in ipairs(frames) do
			if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 1 / 60) end
		end
	end
end

function mock.slash(text, id) _G.SlashCmdList[id or "CORKSPIKE"](text) end
function mock.frames() return frames end
return mock
