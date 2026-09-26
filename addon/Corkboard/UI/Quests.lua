-- The Quests tab (docs/design.md §9.3): what quests each member is on. The
-- members sharing a quest log are listed on the left; the one picked shows on
-- the right, with a tick on every quest you're on too. It sits in the main
-- window's note area while its tab is chosen, like the Members tab.

local _, ns = ...
local View, Commands = ns.View, ns.Commands

local Quests = {}
ns.Quests = Quests
Quests.TAB = 5 -- its bottom tab in the main window

local PAD = 10
local MEMBER_ROW = 34
local QUEST_ROW = 20
local MEMBERS_WIDTH = 150
local RIGHT = PAD + MEMBERS_WIDTH + 22 -- where the member's quests start
local TOP = 32 -- below the sharing option
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }
local TEXT = { 0.9, 0.9, 0.9 }

local panel, ui
local boardId
local selected -- { board, name }: the member shown, until another board is picked
local onlyShared = false

local function addon()
	return ns.Corkboard
end

local function store()
	return addon().store
end

local function retain()
	return ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
end

local function initMember(row, data)
	if not row.name then
		row.selected = row:CreateTexture(nil, "BACKGROUND")
		row.selected:SetAllPoints()
		row.selected:SetColorTexture(1, 0.82, 0, 0.08) -- the board list's gold wash
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("TOPLEFT", 8, -4)
		row.name:SetPoint("TOPRIGHT", -6, -4)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row:SetScript("OnClick", function(self)
			Quests:Select(self.member)
		end)
	end
	row.member = data.name
	row.name:SetText(data.label)
	row.name:SetTextColor(unpack(data.online and (ns.Members.ClassColor(data.class) or TEXT) or DIM))
	row.detail:SetText(data.detail)
	row.selected:SetShown(selected ~= nil and selected.name == data.name)
end

local function initQuest(row, data)
	if not row.shade then
		row.shade = row:CreateTexture(nil, "BACKGROUND")
		row.shade:SetAllPoints()
		row.shade:SetColorTexture(1, 1, 1, 0.03)
		row.mark = row:CreateTexture(nil, "OVERLAY")
		row.mark:SetSize(14, 14)
		row.mark:SetPoint("LEFT", 4, 0)
		row.mark:SetTexture(Commands.SHARED_ICON)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("LEFT", 22, 0)
		row.text:SetPoint("RIGHT", -40, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row.level = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.level:SetPoint("RIGHT", -4, 0)
		row.level:SetWidth(32)
		row.level:SetJustifyH("RIGHT")
		ns.Links.Enable(row)
	end
	row.shade:SetShown(data.index % 2 == 0)
	row.mark:SetShown(data.shared)
	row.text:SetText(data.link)
	row.level:SetText(data.level > 0 and tostring(data.level) or "")
end

local function checkbox(parent, label, onClick)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
	box.label:SetText(label)
	box:SetScript("OnClick", function(self)
		onClick(self:GetChecked() and true or false)
	end)
	return box
end

local function scrollList(template, initializer, extent)
	local list = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", list, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementInitializer(template, initializer)
	view:SetElementExtent(extent)
	ScrollUtil.InitScrollBoxListWithScrollBar(list, bar, view)
	if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
		ScrollUtil.AddManagedScrollBarVisibilityBehavior(list, bar)
	end
	return list
end

function Quests.Build(_, inset)
	panel = CreateFrame("Frame", nil, inset)
	panel:SetAllPoints()
	panel:Hide()
	ui = {}

	ui.share = checkbox(panel, "Share my quest log with this board", function(checked)
		store():setOption(boardId, "quests", checked)
		addon():Changed()
	end)
	ui.share:SetPoint("TOPLEFT", PAD - 4, -PAD + 2)

	ui.members = scrollList("Button", initMember, MEMBER_ROW)
	ui.members:SetPoint("TOPLEFT", PAD, -PAD - TOP)
	ui.members:SetPoint("BOTTOMLEFT", PAD, PAD)
	ui.members:SetWidth(MEMBERS_WIDTH)

	ui.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ui.title:SetPoint("TOPLEFT", RIGHT, -PAD - TOP)
	ui.title:SetPoint("RIGHT", -PAD, 0)
	ui.title:SetJustifyH("LEFT")
	ui.title:SetWordWrap(false)
	ui.detail = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.detail:SetPoint("TOPLEFT", ui.title, "BOTTOMLEFT", 0, -4)
	ui.detail:SetPoint("RIGHT", -PAD, 0)
	ui.detail:SetJustifyH("LEFT")
	ui.detail:SetWordWrap(false)
	ui.onlyShared = checkbox(panel, "Only quests I'm on too", function(checked)
		onlyShared = checked
		Quests:Refresh(store():board(boardId))
	end)
	ui.onlyShared:SetPoint("TOPLEFT", RIGHT - 4, -PAD - TOP - 34)

	ui.quests = scrollList("Frame", initQuest, QUEST_ROW)
	ui.quests:SetPoint("TOPLEFT", RIGHT, -PAD - TOP - 62)
	ui.quests:SetPoint("BOTTOMRIGHT", -PAD - 14, PAD)

	ui.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.empty:SetPoint("TOPLEFT", RIGHT, -PAD - TOP - 70)
	ui.empty:SetPoint("RIGHT", -PAD, 0)
	ui.empty:SetJustifyH("LEFT")
	ui.empty:SetTextColor(unpack(DIM))
	return panel
end

function Quests:Refresh(board)
	if not panel or not panel:IsShown() then
		return
	end
	boardId = board and board.id
	if not board then
		return
	end
	local s = store()
	local now, online = s.env.now(), addon().sync:onlineNames(board.id)
	ui.share:SetChecked(board.quests ~= false)
	local members = View.questMembers(s, board, online)
	if not selected or selected.board ~= board.id then
		selected = members[1] and { board = board.id, name = members[1].name } or nil
	end
	ui.members:SetDataProvider(CreateDataProvider(members), retain())
	local log = View.questLog(s, board, selected and selected.name, online, onlyShared, now)
	ui.title:SetText(log.title)
	ui.detail:SetText(log.detail)
	ui.onlyShared:SetShown(log.filterable == true)
	ui.onlyShared:SetChecked(onlyShared)
	ui.quests:SetDataProvider(CreateDataProvider(log.rows), retain())
	ui.empty:SetText(log.empty or "")
end

-- Shows one member's quests.
function Quests:Select(name)
	selected = boardId and { board = boardId, name = name } or nil
	self:Refresh(store():board(boardId))
end

-- From the Members tab: opens this tab on a member of the current board.
function Quests:ShowMember(id, name)
	selected = { board = id, name = name }
	ns.Main:ShowTab(Quests.TAB)
end

-- For tests: the options, the member list and the quest list.
function Quests.Widgets()
	return ui
end
