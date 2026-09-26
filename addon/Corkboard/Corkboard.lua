-- The WoW side of Corkboard. Keep this file thin: the store, the sync engine,
-- the outbox, the /cork commands and the merge core are pure Lua in Core/,
-- where busted tests them. This file only supplies what they need from the
-- client, and wires up the transport (Net.lua) and the window (UI/).

local ADDON, ns = ...

local Corkboard = {}
ns.Corkboard = Corkboard
_G.Corkboard = Corkboard -- other addons reached it through AceAddon before
Corkboard.Sanitise = ns.Sanitise -- read by spikes/CorkSpike2 (spike 04)

local DEFAULTS = { global = { boards = {} } }
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

local function classToken()
	local _, class = UnitClass("player")
	if not secret(class) and type(class) == "string" then
		return class
	end
end

-- ADDON_LOADED, once SavedVariables are in.
function Corkboard:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("CorkboardDB", DEFAULTS, true)
	self.env = { now = GetServerTime, rand = math.random }
	self.store = ns.Store.new(self.db, self.env)
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
	ns.Net:Init(self)
	C_Timer.NewTicker(PUMP, function()
		self.outbox:pump()
	end)
	-- Join the board channels once the game's own channels have their numbers.
	C_Timer.After(ns.Net.JOIN_DELAY, function()
		self:Identify()
		ns.Net:Start()
		self.sync:start()
	end)
	-- A launcher for broker displays. The minimap button (LibDBIcon) comes
	-- once that library is vendored.
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
				tooltip:AddLine("Click to open your boards.", 1, 1, 1)
			end,
		})
	end
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
	else
		lines = ns.Commands.run(self.store, input)
	end
	for i, line in ipairs(lines) do
		DEFAULT_CHAT_FRAME:AddMessage(i == 1 and PREFIX .. line or line)
	end
	self:Changed()
end
