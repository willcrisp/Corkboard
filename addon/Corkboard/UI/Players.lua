-- The Players tab (docs/design.md §9.4): the board's shared avoid list and
-- good-player list. Each row is a character, the verdict, who noted them and
-- why; hovering one offers Edit and Delete, as on note cards. It sits in the
-- main window's note area while its tab is chosen, like the Members tab.

local _, ns = ...
local button = ns.Main.Button
local View, Players = ns.View, ns.Players

local PlayersTab = {}
ns.PlayersTab = PlayersTab

local PAD = 10
local TOP = 32 -- the filters, search and Add Player row
local ICON = 14
local TEXT_LEFT = 24 -- where the name and reason start, right of the mark
local BYLINE_WIDTH = 130
local ROW_MIN = 24
local ROW_GAP = 6
-- The inset is the window's width less the board list (UI/Main.lua).
local LIST_WIDTH = 720 - 2 * 10 - 180 - 8 - 2 * PAD - 14
local REASON_WIDTH = LIST_WIDTH - TEXT_LEFT - 8
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }
local TEXT = { 0.9, 0.9, 0.9 }

local panel, ui
local boardId
local show = { avoid = true, good = true }

local function addon()
	return ns.Corkboard
end

local function store()
	return addon().store
end

local function retain()
	return ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
end

local function rowEnter(row)
	row.byline:Hide()
	row.edit:Show()
	row.delete:Show()
end

local function rowLeave(row)
	if row:IsMouseOver() then
		return -- moved onto its own Edit or Delete button
	end
	row.byline:Show()
	row.edit:Hide()
	row.delete:Hide()
end

local function iconButton(row, texture, label, onClick)
	local b = CreateFrame("Button", nil, row)
	b:SetSize(16, 16)
	b:SetNormalTexture(texture)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", function()
		onClick(boardId, row.noteId)
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(label)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
		rowLeave(row)
	end)
	b:Hide()
	return b
end

local function initRow(row, data)
	if not row.name then
		row.shade = row:CreateTexture(nil, "BACKGROUND")
		row.shade:SetAllPoints()
		row.shade:SetColorTexture(1, 1, 1, 0.03)
		row.mark = row:CreateTexture(nil, "OVERLAY")
		row.mark:SetSize(ICON, ICON)
		row.mark:SetPoint("TOPLEFT", 4, -4)
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("TOPLEFT", TEXT_LEFT, -4)
		row.name:SetPoint("RIGHT", -BYLINE_WIDTH - 8, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row.byline = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.byline:SetPoint("TOPRIGHT", -4, -5)
		row.byline:SetWidth(BYLINE_WIDTH)
		row.byline:SetJustifyH("RIGHT")
		row.byline:SetWordWrap(false)
		row.delete = iconButton(row, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Delete player note",
			function(id, noteId)
				ns.Popups.DeletePlayer(id, noteId)
			end)
		row.delete:SetPoint("TOPRIGHT", -2, -3)
		row.edit = iconButton(row, "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "Edit player note",
			function(id, noteId)
				ns.PlayerEditor:Open(id, noteId)
			end)
		row.edit:SetPoint("RIGHT", row.delete, "LEFT", -4, 0)
		row.reason = row:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
		row.reason:SetPoint("TOPLEFT", TEXT_LEFT, -21)
		row.reason:SetWidth(REASON_WIDTH)
		row.reason:SetJustifyH("LEFT")
		row.reason:SetJustifyV("TOP")
		row.reason:SetWordWrap(true)
		row.reason:SetNonSpaceWrap(true)
		row.reason:SetTextColor(unpack(TEXT))
		row:EnableMouse(true)
		row:SetScript("OnEnter", rowEnter)
		row:SetScript("OnLeave", rowLeave)
		ns.Links.Enable(row)
	end
	row.noteId = data.noteId
	row.shade:SetShown(data.index % 2 == 0)
	row.mark:SetTexture(View.VERDICT_ICONS[data.verdict])
	row.name:SetText(("%s  %s%s|r"):format(data.name, ns.Commands.VERDICT_CODES[data.verdict], data.label))
	row.byline:SetText(("%s · %s"):format(data.byline, data.age))
	row.reason:SetText(data.reason)
	row.byline:Show()
	row.edit:Hide()
	row.delete:Hide()
end

local function rowHeight(row)
	if row.reason == "" then
		return ROW_MIN
	end
	ui.measure:SetText(row.reason)
	return math.max(ROW_MIN, math.ceil(21 + ui.measure:GetStringHeight() + ROW_GAP))
end

local function checkbox(label, verdict)
	local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
	box.label:SetText(label)
	box:SetScript("OnClick", function(self)
		show[verdict] = self:GetChecked() and true or false
		PlayersTab:Refresh(store():board(boardId))
	end)
	return box
end

function PlayersTab.Build(_, inset)
	panel = CreateFrame("Frame", nil, inset)
	panel:SetAllPoints()
	panel:Hide()
	ui = {}

	ui.avoid = checkbox("Avoid", "avoid")
	ui.avoid:SetPoint("TOPLEFT", PAD - 4, -PAD + 2)
	ui.good = checkbox("Good players", "good")
	ui.good:SetPoint("LEFT", ui.avoid, "RIGHT", 60, 0)

	ui.add = button(panel, "Add Player", 100)
	ui.add:SetPoint("TOPRIGHT", -PAD, -PAD + 2)
	ui.add:SetScript("OnClick", function()
		if boardId then
			ns.PlayerEditor:Open(boardId)
		end
	end)
	ui.search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
	ui.search:SetSize(150, 20)
	ui.search:SetPoint("RIGHT", ui.add, "LEFT", -10, 0)
	ui.search:SetAutoFocus(false)
	ui.search:HookScript("OnTextChanged", function()
		PlayersTab:Refresh(store():board(boardId))
	end)

	ui.list = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	ui.list:SetPoint("TOPLEFT", PAD, -PAD - TOP)
	ui.list:SetPoint("BOTTOMRIGHT", -PAD - 14, PAD + 18)
	local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", ui.list, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", ui.list, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementInitializer("Frame", initRow)
	view:SetElementExtentCalculator(function(_, data)
		return data.height
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(ui.list, bar, view)
	if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
		ScrollUtil.AddManagedScrollBarVisibilityBehavior(ui.list, bar)
	end

	ui.measure = panel:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	ui.measure:SetWidth(REASON_WIDTH)
	ui.measure:SetWordWrap(true)
	ui.measure:SetNonSpaceWrap(true)
	ui.measure:Hide()

	ui.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.empty:SetPoint("CENTER")
	ui.empty:SetWidth(LIST_WIDTH - 40)
	ui.empty:SetTextColor(unpack(DIM))
	ui.count = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.count:SetPoint("BOTTOMLEFT", PAD, PAD)
	return panel
end

function PlayersTab:Refresh(board)
	if not panel or not panel:IsShown() then
		return
	end
	boardId = board and board.id
	if not board then
		return
	end
	local s = store()
	ui.avoid:SetChecked(show.avoid)
	ui.good:SetChecked(show.good)
	local entries = Players.entries(board)
	local rows = View.playerRows(entries, show, ui.search:GetText(), s.env.now(), View.realmOf(s.env.me))
	for _, row in ipairs(rows) do
		row.height = rowHeight(row)
	end
	ui.list:SetDataProvider(CreateDataProvider(rows), retain())
	if #entries == 0 then
		ui.empty:SetText("No players noted yet. Click Add Player to warn the board about someone, "
			.. "or to vouch for a good player.")
	elseif #rows == 0 then
		ui.empty:SetText("No players match.")
	else
		ui.empty:SetText("")
	end
	ui.count:SetText(#entries > 0 and View.playerCount(entries, #rows) or "")
end

-- For tests: the filters, search, Add Player and the list.
function PlayersTab.Widgets()
	return ui
end
