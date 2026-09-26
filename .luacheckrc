-- luacheck config: run `luacheck .` from the repo root.
std = "lua51"
max_line_length = 120
exclude_files = { "addon/Corkboard/Libs/**" }

-- The specs run under busted.
files["addon/spec/**"] = { std = "+busted" }

-- The addon's WoW side: the wrapper and the UI. Core/ stays on plain lua51
-- (purity_spec enforces it).
files["addon/Corkboard/Corkboard.lua"] = {
	self = false, -- methods like Corkboard:Changed() needn't use self
	globals = { "CorkboardCompartment_OnClick" },
	read_globals = {
		"DEFAULT_CHAT_FRAME", "GetNormalizedRealmName", "GetServerTime", "LibStub", "NORMAL_FONT_COLOR_CODE",
		"UnitFullName", "UnitGUID", "issecretvalue",
	},
}
files["addon/Corkboard/UI/**"] = {
	self = false,
	globals = { "StaticPopupDialogs", "UISpecialFrames" },
	read_globals = {
		"ButtonFrameTemplate_HideButtonBar", "ButtonFrameTemplate_HidePortrait", "C_Timer", "CANCEL",
		"ChatEdit_InsertLink", "ChatFontNormal", "ChatFrameUtil", "ClearCursor", "CreateDataProvider", "CreateFrame",
		"CreateScrollBoxListLinearView", "DEFAULT_CHAT_FRAME", "DELETE", "GameTooltip", "GetCursorInfo", "SAVE",
		"ScrollBoxConstants", "ScrollUtil", "ScrollingEdit_OnCursorChanged", "ScrollingEdit_OnUpdate", "SetItemRef",
		"StaticPopup_Show", "UIParent", "hooksecurefunc",
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
