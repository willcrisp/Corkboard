-- luacheck config: run `luacheck .` from the repo root.
std = "lua51"
max_line_length = 120
exclude_files = { "addon/Corkboard/Libs/**" }

-- The specs run under busted.
files["addon/spec/**"] = { std = "+busted" }

-- The addon's WoW wrapper. Core/ stays on plain lua51 (purity_spec enforces it).
files["addon/Corkboard/Corkboard.lua"] = {
	read_globals = {
		"DEFAULT_CHAT_FRAME", "GetNormalizedRealmName", "GetServerTime", "LibStub", "NORMAL_FONT_COLOR_CODE",
		"UnitFullName", "UnitGUID", "issecretvalue",
	},
}

-- Phase 0 spike addons: WoW client globals.
files["spikes/**"] = {
	globals = { "CorkSpikeDB", "SLASH_CORKSPIKE1", "SlashCmdList" },
	read_globals = {
		"BNET_CLIENT_WOW", "BNGetNumFriends", "BNSendGameData", "C_AddOns", "C_BattleNet", "C_ChatInfo", "C_Timer",
		"ChatFontNormal", "ChatFrame_RemoveChannel", "CreateFrame", "DEFAULT_CHAT_FRAME", "Enum", "GetAddOnInfo",
		"GetBuildInfo", "GetChannelName", "GetNormalizedRealmName", "GetNumAddOns", "GetRealmName", "GetTime",
		"GetTimePreciseSec", "InCombatLockdown", "IsAddOnLoaded", "IsEncounterInProgress", "IsInGroup", "IsInGuild",
		"IsInInstance", "JoinTemporaryChannel", "LeaveChannelByName", "NUM_CHAT_WINDOWS", "SendAddonMessage",
		"UIParent", "UISpecialFrames", "UnitFullName", "UnitIsDeadOrGhost", "date", "issecretvalue",
	},
}
