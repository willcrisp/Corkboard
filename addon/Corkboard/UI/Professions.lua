-- The Professions tab (docs/design.md §9.2): each member's professions, each
-- opening on a click into the recipes it holds, or with a search or a level
-- or armour filter, the matching recipes and who knows them, plus this
-- character's "share my recipes here" option. It sits in the main window's
-- note area while its tab is chosen, like the Gear tab.

local _, ns = ...
local View, Recipes = ns.View, ns.Recipes

local Professions = {}
ns.Professions = Professions

local ROW = 22
local PAD = 10
local WHO_WIDTH = 170
local INFO_WIDTH = 120 -- "Level 25 · Leather"
local FILTER_ROW = 28 -- the level boxes and armour checkboxes, under the top row
local TOGGLE = 16 -- the plus / minus on a profession row
local INDENT = TOGGLE + 8 -- a profession's name, after the toggle
local NESTED = INDENT + 12 -- a recipe under an open profession
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }

local panel, ui
local boardId
-- The professions opened on each board (Recipes.key -> true). Local to this
-- session: the tab opens closed after a /reload.
local opened = {}

local function addon()
	return ns.Corkboard
end

local function store()
	return addon().store
end

-- Opens or closes one profession's recipes on the current board.
local function toggle(key)
	if not boardId or not key then
		return
	end
	opened[boardId] = opened[boardId] or {}
	opened[boardId][key] = not opened[boardId][key] or nil
	Professions:Refresh(store():board(boardId))
end

local function initRow(row, data)
	if not row.shade then
		row.shade = row:CreateTexture(nil, "BACKGROUND")
		row.shade:SetAllPoints()
		row.shade:SetColorTexture(1, 1, 1, 0.03)
		row.toggle = row:CreateTexture(nil, "ARTWORK")
		row.toggle:SetSize(TOGGLE, TOGGLE)
		row.toggle:SetPoint("LEFT", 4, 0)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("RIGHT", -WHO_WIDTH - INFO_WIDTH - 12, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row.who = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.who:SetPoint("RIGHT", -4, 0)
		row.who:SetWidth(WHO_WIDTH)
		row.who:SetJustifyH("RIGHT")
		row.who:SetWordWrap(false)
		row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.info:SetPoint("RIGHT", -WHO_WIDTH - 8, 0)
		row.info:SetWidth(INFO_WIDTH)
		row.info:SetJustifyH("LEFT")
		row.info:SetWordWrap(false)
		row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
		row.highlight:SetAllPoints()
		row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.highlight:SetBlendMode("ADD")
		ns.Links.Enable(row)
		-- A click on a profession opens or closes its recipes. Recipe rows
		-- have no key: their link takes the click.
		row:SetScript("OnClick", function(self)
			toggle(self.key)
		end)
	end
	row.key = data.key
	row.shade:SetShown(data.index % 2 == 0)
	row.highlight:SetAlpha(data.key and 1 or 0)
	row.toggle:SetShown(data.key ~= nil)
	if data.key then
		row.toggle:SetTexture(data.open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
		row.toggle:SetDesaturated(data.empty and true or false)
	end
	-- Search results sit at the left edge; a profession's own recipes sit
	-- indented under its name.
	row.text:SetPoint("LEFT", data.key and INDENT or data.nested and NESTED or 4, 0)
	row.text:SetText(data.text)
	row.who:SetText(data.who)
	row.info:SetText(data.info or "")
end

-- The level and armour filter as Recipes.rows takes it.
local function currentFilter()
	local filter = {
		min = tonumber(ui.minLevel:GetText()),
		max = tonumber(ui.maxLevel:GetText()),
		armour = {},
	}
	for armour, box in pairs(ui.armour) do
		if box:GetChecked() then
			filter.armour[armour] = true
		end
	end
	return filter
end

local function refresh()
	Professions:Refresh(store():board(boardId))
end

-- A small numeric box for one end of the level range.
local function levelBox(anchor, x)
	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetSize(30, 20)
	box:SetPoint("LEFT", anchor, "RIGHT", x, 0)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(3)
	box:HookScript("OnTextChanged", refresh)
	return box
end

function Professions.Build(_, inset)
	panel = CreateFrame("Frame", nil, inset)
	panel:SetAllPoints()
	panel:Hide()
	ui = {}

	ui.share = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	ui.share:SetSize(24, 24)
	ui.share:SetPoint("TOPLEFT", PAD - 4, -PAD + 2)
	ui.share.label = ui.share:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.share.label:SetPoint("LEFT", ui.share, "RIGHT", 2, 0)
	ui.share.label:SetText("Share my recipes on this board")
	ui.share:SetScript("OnClick", function(self)
		store():setRecipeSharing(boardId, self:GetChecked() and true or false)
		addon():Changed()
	end)

	ui.search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
	ui.search:SetSize(180, 20)
	ui.search:SetPoint("TOPRIGHT", -PAD - 4, -PAD)
	ui.search:SetAutoFocus(false)
	ui.search:HookScript("OnTextChanged", refresh)

	-- The filters: what a recipe makes, by required level and armour type.
	local level = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	level:SetPoint("TOPLEFT", PAD, -PAD - FILTER_ROW - 4)
	level:SetText("Level")
	ui.minLevel = levelBox(level, 10)
	local dash = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dash:SetPoint("LEFT", ui.minLevel, "RIGHT", 4, 0)
	dash:SetText("–")
	ui.maxLevel = levelBox(dash, 10)
	ui.armour = {}
	local anchor, x = ui.maxLevel, 16
	for _, armour in ipairs(Recipes.ARMOUR) do
		local box = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		box:SetSize(24, 24)
		box:SetPoint("LEFT", anchor, "RIGHT", x, 0)
		box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
		box.label:SetText(Recipes.ARMOUR_NAMES[armour])
		box:SetScript("OnClick", refresh)
		ui.armour[armour] = box
		anchor, x = box.label, 10
	end

	ui.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.empty:SetPoint("CENTER")
	ui.empty:SetTextColor(unpack(DIM))
	ui.empty:SetWidth(360)

	ui.more = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.more:SetPoint("RIGHT", ui.search, "LEFT", -10, 0)

	ui.list = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	ui.list:SetPoint("TOPLEFT", PAD, -PAD - 28 - FILTER_ROW)
	ui.list:SetPoint("BOTTOMRIGHT", -PAD - 14, PAD)
	local bar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", ui.list, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", ui.list, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementInitializer("Button", initRow)
	view:SetElementExtent(ROW)
	ScrollUtil.InitScrollBoxListWithScrollBar(ui.list, bar, view)
	if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
		ScrollUtil.AddManagedScrollBarVisibilityBehavior(ui.list, bar)
	end
	return panel
end

function Professions:Refresh(board)
	if not panel or not panel:IsShown() then
		return
	end
	boardId = board and board.id
	if not board then
		return
	end
	local s = store()
	ui.share:SetChecked(board.recipes ~= false)
	local lists = Recipes.lists(board)
	local myRealm = View.realmOf(s.env.me)
	local query = ui.search:GetText()
	local filter = currentFilter()
	local rows, cut = Recipes.rows(lists, query, function(id)
		return addon():RecipeName(id)
	end, function(name)
		return View.shortName(name, myRealm)
	end, opened[board.id], filter)
	if #lists == 0 then
		ui.empty:SetText("No recipes yet. Open a profession window and your recipes show up here, "
			.. "along with those of members who do the same.")
	elseif #rows == 0 then
		ui.empty:SetText(Recipes.filtering(filter) and "No recipes match your search and filters."
			or "No recipes match your search.")
	else
		ui.empty:SetText("")
	end
	if cut then
		ui.more:SetText(("Showing the first %d. Search for more."):format(Recipes.SHOWN))
	elseif #lists > 0 and not query:find("%S") and not Recipes.filtering(filter) then
		ui.more:SetText("Click a profession to see its recipes.")
	else
		ui.more:SetText("")
	end
	ui.list:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
end

-- For tests: the option, the search box, the filters and the list.
function Professions.Widgets()
	return ui
end
