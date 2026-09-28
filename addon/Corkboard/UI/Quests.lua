-- The Quests tab (docs/design.md §9.3): what quests each member is on, and
-- what they've turned in lately. The members sharing a quest log are listed
-- on the left; the one picked shows on the right, under two small tabs:
-- Quest log, with a tick on every quest you're on too and a plus on a quest
-- whose earlier steps are known (a click lists them, with how far you've
-- got), and Completed, newest first with each chain kept together and
-- joined by a line. It sits in the main window's note area while its tab is
-- chosen, like the Members tab.

local _, ns = ...
local View = ns.View
local format = string.format

local Quests = {}
ns.Quests = Quests
Quests.TAB = 5 -- its bottom tab in the main window

local PAD = 10
local MEMBER_ROW = 34
local QUEST_ROW = 20
local MEMBERS_WIDTH = 150
local RIGHT = PAD + MEMBERS_WIDTH + 22 -- where the member's quests start
local TOP = 32 -- below the sharing option
local TOGGLE = 16 -- the plus / minus, or the chain line, at a row's left
local MARK = 14 -- the ready-check mark
local NESTED = 16 -- how far a chain's earlier steps sit in
local LEVEL_WIDTH = 32
local PART_WIDTH = 46 -- "Part 12"
local WHEN_WIDTH = 60 -- "12d ago"
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }
local TEXT = { 0.9, 0.9, 0.9 }
local MODES = { "log", "done" }

local panel, ui
local boardId
local selected -- { board, name }: the member shown, until another board is picked
local filtered = false -- the checkbox over the list: quests you're on too, or haven't done
local mode = "log" -- which of the member's lists shows: "log" or "done"
-- The quests opened to show their chains, per board (quest id -> true).
-- Local to this session, like the Professions tab's.
local opened = {}

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

-- Opens or closes the earlier steps of one quest's chain.
local function toggle(key)
	if not boardId or not key then
		return
	end
	opened[boardId] = opened[boardId] or {}
	opened[boardId][key] = not opened[boardId][key] or nil
	Quests:Refresh(store():board(boardId))
end

local function initQuest(row, data)
	if not row.shade then
		row.shade = row:CreateTexture(nil, "BACKGROUND")
		row.shade:SetAllPoints()
		row.shade:SetColorTexture(1, 1, 1, 0.03)
		row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
		row.highlight:SetAllPoints()
		row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.highlight:SetBlendMode("ADD")
		row.toggle = row:CreateTexture(nil, "ARTWORK")
		row.toggle:SetSize(TOGGLE, TOGGLE)
		row.toggle:SetPoint("LEFT", 4, 0)
		-- The line joining a chain's steps on the Completed list: a dot on
		-- each step, and a line up and down to the steps next to it.
		row.dot = row:CreateTexture(nil, "ARTWORK")
		row.dot:SetSize(4, 4)
		row.dot:SetPoint("CENTER", row, "LEFT", 4 + TOGGLE / 2, 0)
		row.dot:SetColorTexture(DIM[1], DIM[2], DIM[3], 0.9)
		row.up = row:CreateTexture(nil, "ARTWORK")
		row.up:SetWidth(2)
		row.up:SetPoint("TOP", row, "TOPLEFT", 4 + TOGGLE / 2, 0)
		row.up:SetPoint("BOTTOM", row.dot, "CENTER")
		row.up:SetColorTexture(DIM[1], DIM[2], DIM[3], 0.6)
		row.down = row:CreateTexture(nil, "ARTWORK")
		row.down:SetWidth(2)
		row.down:SetPoint("TOP", row.dot, "CENTER")
		row.down:SetPoint("BOTTOM", row, "BOTTOMLEFT", 4 + TOGGLE / 2, 0)
		row.down:SetColorTexture(DIM[1], DIM[2], DIM[3], 0.6)
		row.mark = row:CreateTexture(nil, "OVERLAY")
		row.mark:SetSize(MARK, MARK)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("RIGHT", -(4 + LEVEL_WIDTH + PART_WIDTH + WHEN_WIDTH + 12), 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row.caption = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.caption:SetPoint("RIGHT", -4, 0)
		row.caption:SetJustifyH("LEFT")
		row.caption:SetWordWrap(false)
		row.level = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.level:SetPoint("RIGHT", -4, 0)
		row.level:SetWidth(LEVEL_WIDTH)
		row.level:SetJustifyH("RIGHT")
		row.part = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.part:SetPoint("RIGHT", -(4 + LEVEL_WIDTH + 4), 0)
		row.part:SetWidth(PART_WIDTH)
		row.part:SetJustifyH("RIGHT")
		row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.when:SetPoint("RIGHT", -(4 + LEVEL_WIDTH + PART_WIDTH + 8), 0)
		row.when:SetWidth(WHEN_WIDTH)
		row.when:SetJustifyH("RIGHT")
		ns.Links.Enable(row)
		-- A click on a quest with a known chain opens or closes it; the link
		-- itself takes its own clicks.
		row:SetScript("OnClick", function(self)
			toggle(self.key)
		end)
	end
	local left = 4 + TOGGLE + 2 + (data.nested and NESTED or 0)
	row.key = data.key
	row.shade:SetShown(data.index % 2 == 0)
	row.highlight:SetAlpha(data.key and 1 or 0)
	row.toggle:SetShown(data.key ~= nil)
	if data.key then
		row.toggle:SetTexture(data.open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
	end
	row.dot:SetShown(data.up == true or data.down == true)
	row.up:SetShown(data.up == true)
	row.down:SetShown(data.down == true)
	row.mark:SetPoint("LEFT", left, 0)
	row.mark:SetShown(data.mark ~= nil)
	if data.mark then
		row.mark:SetTexture(data.mark)
	end
	row.caption:SetPoint("LEFT", left, 0)
	row.caption:SetText(data.caption and data.text or "")
	row.text:SetPoint("LEFT", left + MARK + 4, 0)
	row.text:SetText(data.caption and "" or data.link)
	row.level:SetText(not data.caption and data.level > 0 and tostring(data.level) or "")
	row.part:SetText(data.part or "")
	row.when:SetText(data.when or "")
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
	-- The two lists, as small tabs over them: Quest log and Completed.
	ui.modes = {}
	for i, which in ipairs(MODES) do
		local ok, tab = pcall(CreateFrame, "Button", "CorkboardQuestsMode" .. i, panel, "PanelTopTabButtonTemplate")
		if not ok then
			tab = CreateFrame("Button", "CorkboardQuestsMode" .. i, panel, "TabButtonTemplate")
		end
		tab:SetID(i)
		if i == 1 then
			tab:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", RIGHT, -PAD - TOP - 60)
		else
			tab:SetPoint("LEFT", ui.modes[i - 1], "RIGHT", 2, 0)
		end
		tab:SetScript("OnClick", function()
			Quests:ShowMode(which)
		end)
		ui.modes[i] = tab
	end

	-- The filter, on the right of the tabs, its label to its left.
	ui.onlyShared = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	ui.onlyShared:SetSize(24, 24)
	ui.onlyShared:SetPoint("TOPRIGHT", -PAD - 10, -PAD - TOP - 34)
	ui.onlyShared.label = ui.onlyShared:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.onlyShared.label:SetPoint("RIGHT", ui.onlyShared, "LEFT", -2, 0)
	ui.onlyShared:SetScript("OnClick", function(self)
		filtered = self:GetChecked() and true or false
		Quests:Refresh(store():board(boardId))
	end)

	ui.quests = scrollList("Button", initQuest, QUEST_ROW)
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
	local log = View.questLog(s, board, selected and selected.name, online, filtered, now, mode, opened[board.id])
	ui.title:SetText(log.title)
	ui.detail:SetText(log.detail)
	for i, tab in ipairs(ui.modes) do
		local which = MODES[i]
		tab:SetText(format(which == "log" and "Quest log (%d)" or "Completed (%d)", log.counts[which]))
		tab:SetEnabled(which ~= mode)
		if which == mode and PanelTemplates_SelectTab then
			PanelTemplates_SelectTab(tab)
		elseif which ~= mode and PanelTemplates_DeselectTab then
			PanelTemplates_DeselectTab(tab)
		end
		if PanelTemplates_TabResize then
			PanelTemplates_TabResize(tab, 0)
		end
	end
	ui.onlyShared:SetShown(log.filterable == true)
	ui.onlyShared:SetChecked(filtered)
	ui.onlyShared.label:SetText(log.filterLabel or "")
	ui.quests:SetDataProvider(CreateDataProvider(log.rows), retain())
	ui.empty:SetText(log.empty or "")
end

-- Shows the member's quest log ("log") or the quests they've turned in
-- ("done"). The filter is cleared, since it means something else on each.
function Quests:ShowMode(which)
	if which ~= mode then
		mode = which
		filtered = false
	end
	self:Refresh(store():board(boardId))
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

-- For tests: the options, the mode tabs, the member list and the quest list.
function Quests.Widgets()
	return ui
end
