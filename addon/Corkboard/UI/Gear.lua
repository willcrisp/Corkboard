-- The Gear tab (docs/design.md §9.1): the board's gear feed, newest first,
-- and this character's "post my gear here" option. It sits in the main
-- window's note area while its tab is chosen, like the Members tab.

local _, ns = ...
local View, Store = ns.View, ns.Store

local Gear = {}
ns.Gear = Gear

local ROW = 22
local PAD = 10
local AGE_WIDTH = 60
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }

local panel, ui
local boardId

local function addon()
	return ns.Corkboard
end

local function store()
	return addon().store
end

local function initRow(row, data)
	if not row.shade then
		row.shade = row:CreateTexture(nil, "BACKGROUND")
		row.shade:SetAllPoints()
		row.shade:SetColorTexture(1, 1, 1, 0.03)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("LEFT", 4, 0)
		row.text:SetPoint("RIGHT", -AGE_WIDTH - 8, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row.age = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.age:SetPoint("RIGHT", -4, 0)
		row.age:SetWidth(AGE_WIDTH)
		row.age:SetJustifyH("RIGHT")
		ns.Links.Enable(row)
	end
	row.shade:SetShown(data.index % 2 == 0)
	row.text:SetText(("%s equipped %s"):format(data.who, data.link))
	row.age:SetText(data.age)
end

function Gear.Build(_, inset)
	panel = CreateFrame("Frame", nil, inset)
	panel:SetAllPoints()
	panel:Hide()
	ui = {}

	ui.post = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	ui.post:SetSize(24, 24)
	ui.post:SetPoint("TOPLEFT", PAD - 4, -PAD + 2)
	ui.post.label = ui.post:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.post.label:SetPoint("LEFT", ui.post, "RIGHT", 2, 0)
	ui.post.label:SetText("Post my new rare and epic gear to this board")
	ui.post:SetScript("OnClick", function(self)
		store():setOption(boardId, "gear", self:GetChecked() and true or false)
		addon():Changed()
	end)

	ui.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.empty:SetPoint("CENTER")
	ui.empty:SetTextColor(unpack(DIM))

	ui.list = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	ui.list:SetPoint("TOPLEFT", PAD, -PAD - 28)
	ui.list:SetPoint("BOTTOMRIGHT", -PAD - 14, PAD)
	local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", ui.list, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", ui.list, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementInitializer("Frame", initRow)
	view:SetElementExtent(ROW)
	ScrollUtil.InitScrollBoxListWithScrollBar(ui.list, bar, view)
	if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
		ScrollUtil.AddManagedScrollBarVisibilityBehavior(ui.list, bar)
	end
	return panel
end

function Gear:Refresh(board)
	if not panel or not panel:IsShown() then
		return
	end
	boardId = board and board.id
	if not board then
		return
	end
	local s = store()
	ui.post:SetChecked(board.gear ~= false)
	local rows = View.gearRows(Store.gear(board), Store.GEAR_SHOWN, s.env.now(), View.realmOf(s.env.me))
	ui.empty:SetText(#rows == 0 and "No gear yet. Rare and epic items members equip show up here." or "")
	ui.list:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
end

-- For tests: the option and the feed.
function Gear.Widgets()
	return ui
end
