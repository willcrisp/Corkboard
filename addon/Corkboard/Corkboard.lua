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

-- The open profession window's profession and learned recipe ids (§9.2), or
-- nil when no window is ready, it shows someone else's recipes (a linked,
-- guild or NPC view), or anything read back is a secret value.
local SKIPPED_VIEWS = { "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting", "IsRuneforging" }
local SKIPPED_RECIPES = { "isDummyRecipe", "isRecraft", "isSalvageRecipe", "isGatheringRecipe" }

local function openProfession()
	local T = C_TradeSkillUI
	if not T or not T.IsTradeSkillReady or not T.IsTradeSkillReady() then
		return nil
	end
	for _, check in ipairs(SKIPPED_VIEWS) do
		if T[check] and T[check]() then
			return nil
		end
	end
	local info = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
	if type(info) ~= "table" then
		return nil
	end
	local profession = {
		id = info.professionID,
		name = info.professionName,
		skill = info.skillLevel,
		max = info.maxSkillLevel,
	}
	for _, value in pairs(profession) do
		if secret(value) then
			return nil
		end
	end
	if type(profession.id) ~= "number" or profession.id <= 0 then
		return nil
	end
	local ids = {}
	for _, id in ipairs(T.GetAllRecipeIDs() or {}) do
		local recipe = not secret(id) and T.GetRecipeInfo(id)
		if type(recipe) == "table" and not secret(recipe.learned) and recipe.learned == true then
			local skip = false
			for _, field in ipairs(SKIPPED_RECIPES) do
				if secret(recipe[field]) or recipe[field] == true then
					skip = true
				end
			end
			if not skip then
				ids[#ids + 1] = id
			end
		end
	end
	return profession, ids
end

-- The quest log (§9.3), as { id, level, title } for each quest, headers and
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
	self.questTitles, self.questRequested = {}, {} -- quest id -> title, and titles asked for (§9.3)
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
		-- A joined board shares recipe lists once it has synced (§9.2).
		synced = function(boardId)
			self.store:shareRecipes(boardId)
		end,
	}
	self.sync = ns.Sync.new(self.store, self.outbox, self.syncEnv)
	self.store:listen(function(change)
		self.playerIndex = nil -- rebuilt on the next tooltip or group check (§9.4)
		if change.kind == "board" or change.kind == "deleted" then
			ns.Net:Refresh()
		end
		-- A created or joined board gets this character's kept recipe lists (§9.2).
		if change.kind == "board" then
			self.store:shareRecipes(change.board)
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
	self:WatchProfessions()
	self:WatchQuests()
	self:WatchPlayers()
	ns.Net:Init(self)
	C_Timer.NewTicker(PUMP, function()
		self.outbox:pump()
	end)
	-- Join the board channels once the game's own channels have their numbers.
	C_Timer.After(ns.Net.JOIN_DELAY, function()
		self:Identify()
		self:SeedGear() -- in case the name wasn't known at login
		self.store:shareRecipes() -- kept scans, to boards joined on another character
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

-- Professions tab (§9.2) -----------------------------------------------------------

-- A scan is wanted when a profession window opens or switches profession, or
-- a recipe is learned, and runs once the window's data is ready. Not on every
-- TRADE_SKILL_LIST_UPDATE: that fires on each craft, and re-sending a recipe
-- list per skill-up would use up the throttle (§5.6).
local WANT_SCAN = { TRADE_SKILL_SHOW = true, TRADE_SKILL_DATA_SOURCE_CHANGED = true, NEW_RECIPE_LEARNED = true }

function Corkboard:ScanProfession()
	local profession, ids = openProfession()
	if not profession then
		return nil
	end
	self.scanWanted = false
	self:Identify()
	return self.store:learned(profession, ids)
end

function Corkboard:WatchProfessions()
	if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then
		return
	end
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_LIST_UPDATE",
		"NEW_RECIPE_LEARNED", "TRADE_SKILL_CLOSE" }) do
		pcall(events.RegisterEvent, events, event) -- an event this client lacks raises an error
	end
	events:SetScript("OnEvent", function(_, event)
		if WANT_SCAN[event] then
			self.scanWanted = true
		end
		if self.scanWanted and event ~= "TRADE_SKILL_CLOSE" then
			self:ScanProfession()
		end
	end)
end

-- A recipe's name on this client, or nil. The recipe id is the craft's spell
-- id, so the spell API names recipes from professions this character lacks.
local recipeNames = {}

function Corkboard:RecipeName(id)
	if recipeNames[id] then
		return recipeNames[id]
	end
	local name
	if C_Spell and C_Spell.GetSpellName then
		name = C_Spell.GetSpellName(id)
	end
	if (secret(name) or name == nil) and GetSpellInfo then
		name = GetSpellInfo(id)
	end
	if secret(name) or type(name) ~= "string" or name == "" then
		return nil
	end
	recipeNames[id] = name
	return name
end

-- Quest logs (§9.3) ----------------------------------------------------------------

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

-- Player notes (§9.4) ---------------------------------------------------------------

-- A player unit's name ("Name", or "Name-Realm" for another realm), or nil
-- for a unit that isn't a player or a name the client keeps secret.
-- GetPlayerInfoByGUID gives Forever's whole name, surname and all; UnitName
-- is the fallback while the client hasn't cached the player.
function Corkboard:UnitPlayerName(unit)
	if not UnitExists(unit) or not UnitIsPlayer then
		return nil
	end
	local isPlayer = UnitIsPlayer(unit)
	if secret(isPlayer) or not isPlayer then
		return nil
	end
	local guid = UnitGUID(unit)
	if guid and not secret(guid) then
		local name, realm = select(6, GetPlayerInfoByGUID(guid))
		if type(name) == "string" and name ~= "" and not secret(name) and not secret(realm) then
			if type(realm) == "string" and realm ~= "" then
				name = name .. "-" .. realm
			end
			return name
		end
	end
	local name = UnitName(unit)
	if type(name) == "string" and name ~= "" and not secret(name) then
		return name
	end
end

-- What the boards on this account say about a player (Players.lookup), from
-- an index rebuilt after any change to the store.
function Corkboard:PlayerNotes(name)
	local key = ns.Players.key(name)
	if not key then
		return {}
	end
	self.playerIndex = self.playerIndex or ns.Players.index(self.store:boards())
	return self.playerIndex[key] or {}
end

-- Adds the boards' verdicts on a player to their unit tooltip.
function Corkboard:AddPlayerLines(tooltip, unit)
	local name = self:UnitPlayerName(unit)
	local found = name and self:PlayerNotes(name) or {}
	if #found == 0 then
		return
	end
	for _, line in ipairs(ns.View.playerTooltip(found, ns.View.realmOf(self.env.me))) do
		local c = line.color
		if line.right then
			tooltip:AddDoubleLine(line.left, line.right, c[1], c[2], c[3], 0.62, 0.62, 0.62)
		else
			tooltip:AddLine(line.left, c[1], c[2], c[3])
		end
		if line.reason then
			tooltip:AddLine(line.reason, 0.9, 0.9, 0.9, true)
		end
	end
	tooltip:Show() -- resizes it to the new lines
end

-- The units in the player's group, other than the player.
local function groupUnits()
	local count = GetNumGroupMembers and GetNumGroupMembers() or 0
	if type(count) ~= "number" or secret(count) then
		return {}
	end
	local units = {}
	if IsInRaid() then
		for i = 1, count do
			units[#units + 1] = "raid" .. i
		end
	else
		for i = 1, count - 1 do
			units[#units + 1] = "party" .. i
		end
	end
	return units
end

-- Warns in chat, once per session, about each player in the group whom a
-- board says to avoid. Leaving the group resets it, so the next group they
-- turn up in warns again.
function Corkboard:CheckGroup()
	if not IsInGroup() then
		self.warnedPlayers = {}
		return
	end
	self.warnedPlayers = self.warnedPlayers or {}
	local myKey = ns.Players.key(self:Identify())
	for _, unit in ipairs(groupUnits()) do
		local name = self:UnitPlayerName(unit)
		local key = name and ns.Players.key(name)
		if key and key ~= myKey and not self.warnedPlayers[key] then
			local found = self:PlayerNotes(name)
			if found[1] and found[1].verdict == "avoid" then
				self.warnedPlayers[key] = true
				self:Print(ns.Commands.playerWarning(found, self.env.me, GetServerTime()))
			end
		end
	end
end

function Corkboard:WatchPlayers()
	local function onTooltip(tooltip)
		if tooltip ~= GameTooltip or not tooltip.GetUnit then
			return
		end
		local _, unit = tooltip:GetUnit()
		if unit and not secret(unit) then
			self:AddPlayerLines(tooltip, unit)
		end
	end
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, onTooltip)
	elseif GameTooltip:HasScript("OnTooltipSetUnit") then
		GameTooltip:HookScript("OnTooltipSetUnit", onTooltip) -- a post-hook, like hooksecurefunc
	end
	-- The roster changes in bursts as a group forms, so check once it settles.
	local events = CreateFrame("Frame")
	events:RegisterEvent("GROUP_ROSTER_UPDATE")
	events:SetScript("OnEvent", function()
		if self.groupCheckPending then
			return
		end
		self.groupCheckPending = true
		C_Timer.After(1, function()
			self.groupCheckPending = false
			self:CheckGroup()
		end)
	end)
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
