-- The WoW side of Corkboard. Keep this file thin: the store, the /cork
-- commands and the merge core are pure Lua in Core/, where busted tests them.
-- This file only supplies what they need from the client.

local ADDON, ns = ...

local Corkboard = LibStub("AceAddon-3.0"):NewAddon(ADDON, "AceConsole-3.0")
ns.Corkboard = Corkboard

local DEFAULTS = { global = { boards = {} } }
local PREFIX = (NORMAL_FONT_COLOR_CODE or "|cffffd100") .. "Corkboard:|r " -- docs/ui-style.md

local function secret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

-- The player's "Name-Realm" and note-id prefix, or nil while either is
-- unknown or a secret value. The prefix is hashed from the GUID once, so it
-- is plain data by the time any note carries it.
local function identity()
	local name, realm = UnitFullName("player")
	local guid = UnitGUID("player")
	if secret(name) or secret(realm) or secret(guid) then
		return nil
	end
	if not realm or realm == "" then
		realm = GetNormalizedRealmName()
	end
	if not name or not realm or realm == "" or not guid then
		return nil
	end
	return name .. "-" .. realm, ns.Store.notePrefix(guid)
end

function Corkboard:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("CorkboardDB", DEFAULTS, true)
	self.env = { now = GetServerTime, rand = math.random }
	self.store = ns.Store.new(self.db, self.env)
	self:RegisterChatCommand("cork", "OnSlash")
end

-- PLAYER_LOGIN
function Corkboard:OnEnable()
	self:Identify()
end

function Corkboard:Identify()
	if not self.env.me then
		self.env.me, self.env.prefix = identity()
	end
	return self.env.me
end

function Corkboard:OnSlash(input)
	self:Identify()
	for i, line in ipairs(ns.Commands.run(self.store, input)) do
		DEFAULT_CHAT_FRAME:AddMessage(i == 1 and PREFIX .. line or line)
	end
end
