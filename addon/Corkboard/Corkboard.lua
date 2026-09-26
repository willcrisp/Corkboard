-- The WoW side of Corkboard. Keep this file thin: the store, the sync engine,
-- the outbox, the /cork commands and the merge core are pure Lua in Core/,
-- where busted tests them. This file only supplies what they need from the
-- client, and wires up the transport (Net.lua) and the window (UI/).

local ADDON, ns = ...

local Corkboard = {}
ns.Corkboard = Corkboard
_G.Corkboard = Corkboard -- other addons reached it through AceAddon before
Corkboard.Sanitise = ns.Sanitise -- read by spikes/CorkSpike2 (spike 04)

-- minimap is LibDBIcon's own table: minimapPos (degrees round the minimap) and hide.
local DEFAULTS = { global = { boards = {}, minimap = { hide = false } } }
local PREFIX = (NORMAL_FONT_COLOR_CODE or "|cffffd100") .. "Corkboard:|r " -- docs/ui-style.md
local WARNING = "|cffffff00"
local PUMP = 0.5 -- seconds between outbox pumps

local function secret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

-- The player's "Name-Realm" and note-id prefix, or nil while either is
-- unknown or a secret value. The prefix is hashed from the GUID once, so it
-- is plain data by the time any note carries it.
--
-- The name must match how CHAT_MSG_ADDON names us to others. Forever names
-- have surnames: on 1.60.1 UnitFullName("player") gives "Aprune",
-- "Proudshield" (the surname where the realm should be), while senders
-- arrive as "Aprune Proudshield-ClassicBetaPvP2". GetPlayerInfoByGUID gives
-- the whole "Aprune Proudshield" and an empty realm for our own.
local function identity()
	local guid = UnitGUID("player")
	if not guid or secret(guid) then
		return nil
	end
	local name, realm = select(6, GetPlayerInfoByGUID(guid))
	if secret(name) or secret(realm) then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	end
	if not name or name == "" or not realm or realm == "" then
		return nil
	end
	return name .. "-" .. realm, ns.Store.notePrefix(guid)
end

-- The gear feed (§9.1) watches equipment slots 1-19 (head to tabard).
local GEAR_SLOTS = 19

-- The item in an equipment slot: its id, link and quality, or nil when the
-- slot is empty or the client hides the link.
local function equippedItem(slot)
	local link = GetInventoryItemLink("player", slot)
	if type(link) ~= "string" or secret(link) then
		return nil
	end
	local itemId = tonumber(link:match("|Hitem:(%d+)"))
	if not itemId then
		return nil
	end
	local quality = GetInventoryItemQuality and GetInventoryItemQuality("player", slot)
	if (quality == nil or secret(quality)) and C_Item and C_Item.GetItemQualityByID then
		quality = C_Item.GetItemQualityByID(link)
	end
	if secret(quality) then
		quality = nil
	end
	return itemId, link, quality
end

-- The quest log (§9.2), as { id, level, title } for each quest, headers and
-- hidden entries left out. Nil when the client has no quest log API or hands
-- back a secret value, so nothing is published from it.
local function readQuestLog()
	local quests = {}
	local function add(id, level, title)
		if secret(id) or secret(level) or secret(title) then
			return false
		end
		if type(id) == "number" and id > 0 then
			quests[#quests + 1] = {
				id = id,
				level = type(level) == "number" and level or 0,
				title = type(title) == "string" and title ~= "" and title or nil,
			}
		end
		return true
	end
	if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
		local count = C_QuestLog.GetNumQuestLogEntries()
		if type(count) ~= "number" or secret(count) then
			return nil
		end
		for i = 1, count do
			local info = C_QuestLog.GetInfo(i)
			if type(info) == "table" and not info.isHeader and not info.isHidden
				and not add(info.questID, info.level, info.title) then
				return nil
			end
		end
	elseif GetNumQuestLogEntries and GetQuestLogTitle then
		local count = GetNumQuestLogEntries()
		if type(count) ~= "number" or secret(count) then
			return nil
		end
		for i = 1, count do
			local title, level, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
			if not isHeader and not add(id, level, title) then
				return nil
			end
		end
	else
		return nil
	end
	return quests
end

-- Quest events land in bursts (accepting a quest fires several, and every
-- kill with an objective fires QUEST_LOG_UPDATE), so the log is read once
-- they settle. An unchanged log sends nothing.
local QUEST_DELAY = 2
local QUEST_EVENTS = { "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
	"QUEST_DATA_LOAD_RESULT" }

local function classToken()
	local _, class = UnitClass("player")
	if not secret(class) and type(class) == "string" then
		return class
	end
end

-- ADDON_LOADED, once SavedVariables are in.
function Corkboard:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("CorkboardDB", DEFAULTS, true)
	self.env = {
		now = GetServerTime,
		rand = math.random,
		questTitle = function(id)
			return self:QuestTitle(id)
		end,
	}
	self.store = ns.Store.new(self.db, self.env)
	self.questTitles, self.questRequested = {}, {} -- quest id -> title, and titles asked for (§9.2)
	self.gate = ns.Gate.new(function(name)
		return _G[name]
	end)
	self.wire = ns.Wire.new(LibStub("LibSerialize"), LibStub("LibDeflate"))
	self.outbox = ns.Outbox.new({
		now = GetTime,
		restricted = function()
			return self.gate:restricted()
		end,
		encode = function(envelope)
			return self.wire:encode(envelope)
		end,
		send = function(dest, text, prio, done)
			ns.Net:Send(dest, text, prio, done)
		end,
		ready = function(dest)
			return ns.Net:Ready(dest)
		end,
		onOpen = function()
			self.sync:onGateOpen()
		end,
	})
	self.syncEnv = {
		time = GetTime,
		after = function(seconds, fn)
			return C_Timer.NewTimer(seconds, fn)
		end,
		random = math.random,
		changed = function()
			self:ChangedSoon()
		end,
	}
	self.sync = ns.Sync.new(self.store, self.outbox, self.syncEnv)
	self.store:listen(function(change)
		if change.kind == "board" or change.kind == "deleted" then
			ns.Net:Refresh()
		end
	end)
	SLASH_CORK1 = "/cork"
	SlashCmdList.CORK = function(input)
		self:OnSlash(input)
	end
end

-- PLAYER_LOGIN
function Corkboard:OnEnable()
	self:Identify()
	self.syncEnv.class = classToken()
	-- Notes the companion fetched from the cloud since the last session (§7.2).
	ns.Cloud.load(self.store, _G.CorkboardCloudData)
	self:WatchGear()
	self:WatchQuests()
	ns.Net:Init(self)
	C_Timer.NewTicker(PUMP, function()
		self.outbox:pump()
	end)
	-- Join the board channels once the game's own channels have their numbers.
	C_Timer.After(ns.Net.JOIN_DELAY, function()
		self:Identify()
		self:SeedGear() -- in case the name wasn't known at login
		self:ScanQuestsSoon()
		ns.Net:Start()
		self.sync:start()
	end)
	-- A launcher for broker displays, and the minimap button that shows it.
	local LDB = LibStub("LibDataBroker-1.1", true)
	if LDB then
		self.launcher = LDB:NewDataObject(ADDON, {
			type = "launcher",
			label = ADDON,
			icon = ns.Main.ICON,
			OnClick = function()
				Corkboard:Toggle()
			end,
			OnTooltipShow = function(tooltip)
				tooltip:AddLine(ADDON)
				for _, line in ipairs(ns.View.tooltipLines(self.store, self.sync)) do
					tooltip:AddLine(line[1], line[2], line[3], line[4])
				end
				tooltip:AddLine("Click to open your boards. Drag to move this button.", 1, 1, 1)
			end,
		})
		local icon = LibStub("LibDBIcon-1.0", true)
		if icon then
			icon:Register(ADDON, self.launcher, self.db.global.minimap)
		end
	end
end

-- /cork minimap: shows or hides the minimap button, remembered per account.
function Corkboard:ToggleMinimap()
	local settings = self.db.global.minimap
	settings.hide = not settings.hide
	local icon = LibStub("LibDBIcon-1.0", true)
	if icon then
		if settings.hide then
			icon:Hide(ADDON)
		else
			icon:Show(ADDON)
		end
	end
	return settings.hide and "Minimap button hidden. /cork minimap brings it back." or "Minimap button shown."
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" and name == ADDON then
		Corkboard:OnInitialize()
	elseif event == "PLAYER_LOGIN" then
		Corkboard:OnEnable()
	end
end)

-- The addon compartment by the minimap (## AddonCompartmentFunc in the TOC).
function CorkboardCompartment_OnClick()
	Corkboard:Toggle()
end

function Corkboard:Toggle()
	self:Identify()
	ns.Main:Toggle()
end

-- Call after any change to the store, so an open window shows it.
function Corkboard:Changed()
	ns.Main:Refresh()
	if ns.Debug then
		ns.Debug:Refresh()
	end
end

-- Sync changes arrive a message at a time, so a catch-up would redraw the
-- window per PUT. This coalesces them into one redraw.
function Corkboard:ChangedSoon()
	if self.refreshPending then
		return
	end
	self.refreshPending = true
	C_Timer.After(0.2, function()
		self.refreshPending = false
		self:Changed()
	end)
end

function Corkboard:Print(text)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

function Corkboard:Warn(text)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. WARNING .. text .. "|r")
end

-- The board's channel refused our password: its secret was rotated.
function Corkboard:Expired(board)
	self:Warn(("%s: that invite is out of date. Ask the board owner for a new one."):format(ns.Store.name(board)))
	if ns.Popups and ns.Popups.Expired then
		ns.Popups.Expired(board.id)
	end
	self:Changed()
end

function Corkboard:Identify()
	if not self.env.me then
		self.env.me, self.env.prefix = identity()
	end
	return self.env.me
end

-- /cork sync and /cork debug need the running addon; everything else is a
-- store command in Core/Commands.lua.
-- Gear feed (§9.1) ---------------------------------------------------------------

-- What's already equipped counts as seen, so only later upgrades post.
function Corkboard:SeedGear()
	for slot = 1, GEAR_SLOTS do
		local itemId, link, quality = equippedItem(slot)
		if itemId then
			self.store:equipped(itemId, link, quality, true)
		end
	end
end

function Corkboard:WatchGear()
	self:SeedGear()
	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
	events:SetScript("OnEvent", function(_, _, slot)
		if type(slot) ~= "number" or slot < 1 or slot > GEAR_SLOTS then
			return
		end
		local itemId, link, quality = equippedItem(slot)
		if itemId then
			self:Identify()
			self.store:equipped(itemId, link, quality)
		end
	end)
end

-- Quest logs (§9.2) ----------------------------------------------------------------

-- Reads the quest log and shares it. Nothing is read before the client's
-- first QUEST_LOG_UPDATE: until then the log can look empty, and sharing an
-- empty log at every login would briefly wipe it for everyone.
function Corkboard:ScanQuests()
	if not self.questsReady then
		return
	end
	local quests = readQuestLog()
	if not quests then
		return
	end
	for _, quest in ipairs(quests) do
		if quest.title then
			self.questTitles[quest.id] = quest.title
		end
	end
	self:Identify()
	local boards, changed = self.store:questLog(quests)
	if changed or (boards or 0) > 0 then
		self:ChangedSoon()
	end
end

function Corkboard:ScanQuestsSoon()
	if self.questScanPending then
		return
	end
	self.questScanPending = true
	C_Timer.After(QUEST_DELAY, function()
		self.questScanPending = false
		self:ScanQuests()
	end)
end

function Corkboard:WatchQuests()
	local events = CreateFrame("Frame")
	for _, event in ipairs(QUEST_EVENTS) do
		pcall(events.RegisterEvent, events, event) -- a client without the event raises an error
	end
	events:SetScript("OnEvent", function(_, event)
		if event == "QUEST_DATA_LOAD_RESULT" then
			self:ChangedSoon() -- a title the Quests tab asked for has arrived
			return
		end
		if event == "QUEST_LOG_UPDATE" then
			self.questsReady = true
		end
		self:ScanQuestsSoon()
	end)
end

-- A quest's title: from our own quest log, or the client's quest data, which
-- it may have to load first (QUEST_DATA_LOAD_RESULT says when it has).
-- Members share only quest ids, so this is how their quests get names.
function Corkboard:QuestTitle(id)
	local title = self.questTitles[id]
	if title then
		return title
	end
	if C_QuestLog and C_QuestLog.GetTitleForQuestID then
		title = C_QuestLog.GetTitleForQuestID(id)
		if type(title) == "string" and title ~= "" and not secret(title) then
			self.questTitles[id] = title
			return title
		end
		if C_QuestLog.RequestLoadQuestByID and not self.questRequested[id] then
			self.questRequested[id] = true
			C_QuestLog.RequestLoadQuestByID(id)
		end
	end
end

function Corkboard:OnSlash(input)
	if not input or not input:find("%S") then
		return self:Toggle()
	end
	self:Identify()
	local word = input:match("^%s*(%S+)"):lower()
	local lines
	if word == "sync" then
		self.sync:helloAll()
		lines = { "Asking members for changes on every board." }
	elseif word == "debug" then
		ns.Debug:Toggle()
		return
	elseif word == "minimap" then
		lines = { self:ToggleMinimap() }
	else
		lines = ns.Commands.run(self.store, input)
	end
	for i, line in ipairs(lines) do
		DEFAULT_CHAT_FRAME:AddMessage(i == 1 and PREFIX .. line or line)
	end
	self:Changed()
end
