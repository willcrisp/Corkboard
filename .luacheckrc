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
	globals = { "Corkboard", "CorkboardCompartment_OnClick", "SLASH_CORK1", "SlashCmdList" },
	read_globals = {
		"C_Timer", "CreateFrame", "DEFAULT_CHAT_FRAME", "GetNormalizedRealmName", "GetServerTime", "GetTime", "LibStub",
		"NORMAL_FONT_COLOR_CODE", "UnitClass", "GetPlayerInfoByGUID", "UnitGUID", "issecretvalue",
		"C_Item", "GetInventoryItemLink", "GetInventoryItemQuality", "C_Spell", "C_TradeSkillUI", "GetSpellInfo",
	},
}
files["addon/Corkboard/Net.lua"] = {
	self = false,
	read_globals = {
		"C_ChatInfo", "ChatFrameUtil", "ChatFrame_AddMessageEventFilter", "ChatFrame_RemoveChannel", "ChatThrottleLib",
		"CreateFrame", "GetChannelName", "GetNormalizedRealmName", "GetTime", "IsInGuild", "JoinTemporaryChannel",
		"LeaveChannelByName", "NUM_CHAT_WINDOWS", "issecretvalue",
	},
}
files["addon/Corkboard/UI/**"] = {
	self = false,
	globals = { "StaticPopupDialogs", "UISpecialFrames" },
	read_globals = {
		"ButtonFrameTemplate_HideButtonBar", "ButtonFrameTemplate_HidePortrait", "C_ClassColor", "C_Timer", "CANCEL",
		"OKAY", "PanelTemplates_SetNumTabs", "PanelTemplates_SetTab", "PanelTemplates_TabResize", "RAID_CLASS_COLORS",
		"ReloadUI", "date",
		"ChatEdit_InsertLink", "ChatFontNormal", "ChatFrameUtil", "ClearCursor", "CreateDataProvider", "CreateFrame",
		"CreateScrollBoxListLinearView", "DEFAULT_CHAT_FRAME", "DELETE", "GameTooltip", "GetCursorInfo", "SAVE",
		"ScrollBoxConstants", "ScrollUtil", "ScrollingEdit_OnCursorChanged", "ScrollingEdit_OnUpdate", "SetItemRef",
		"StaticPopup_Show", "UIParent", "hooksecurefunc",
	},
}

-- Phase 0 spike addons: WoW client globals.
files["spikes/**"] = {
	globals = { "CorkSpikeDB", "CorkSpike2DB", "SLASH_CORKSPIKE1", "SLASH_CORKSPIKETWO1", "SlashCmdList" },
	read_globals = {
		"BNET_CLIENT_WOW", "BNGetNumFriends", "BNSendGameData", "C_AddOns", "C_BattleNet", "C_ChatInfo", "C_Container",
		"C_CurrencyInfo", "C_Item", "C_QuestLog", "C_Spell", "C_Timer", "ChatEdit_GetActiveWindow", "Corkboard",
		"ChatEdit_InsertLink", "ChatFontNormal", "ChatFrameUtil", "ChatFrame_RemoveChannel", "CreateFrame",
		"DEFAULT_CHAT_FRAME", "Enum", "GameTooltip", "GetAchievementLink", "GetAddOnInfo", "GetBuildInfo", "GetCVar",
		"GetChannelList", "GetChannelName", "GetChatWindowChannels", "GetCurrentRegionName", "GetItemInfo",
		"GetLocale", "GetNormalizedRealmName", "GetNumAddOns", "GetQuestLink", "GetRealmName", "GetSpellLink",
		"GetTime", "GetTimePreciseSec", "InCombatLockdown", "IsAddOnLoaded", "IsEncounterInProgress", "IsInGroup",
		"IsInGuild", "IsInInstance", "JoinTemporaryChannel", "LeaveChannelByName", "LibStub", "NUM_CHAT_WINDOWS",
		"SendAddonMessage", "UIParent", "UISpecialFrames", "UnitFactionGroup", "UnitFullName", "UnitIsDeadOrGhost",
		"date", "hooksecurefunc", "issecretvalue",
	},
}
