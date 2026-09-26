-- The board window (docs/ui-style.md "Board view", docs/mockups/Main.dc.html):
-- the board list on the left, a two-column grid of note cards on the right, a
-- search box, New Note, and a status line. Built from Blizzard templates on
-- first open. What to show comes from Core/View.lua; changes go through
-- the store.

local _, ns = ...
local View, Store = ns.View, ns.Store

local Main = {}
ns.Main = Main

Main.ICON = "Interface\\Icons\\INV_Misc_Note_01"

-- Layout, in UI units. The window is a fixed size, so the note column's
-- width is known up front and card heights can be measured before layout.
local WIDTH, HEIGHT = 720, 500
local LIST_WIDTH = 180
local MARGIN, GAP = 10, 8
local INSET_PAD = 6
local SCROLLBAR = 14
local NOTES_WIDTH = WIDTH - 2 * MARGIN - LIST_WIDTH - GAP - 2 * INSET_PAD - SCROLLBAR
local CARD_GAP = 8
local CARD_PAD = 8
local CARD_HEADER = 14
local CARD_WIDTH = (NOTES_WIDTH - CARD_GAP) / 2
local CARD_TEXT_WIDTH = CARD_WIDTH - 2 * CARD_PAD
local CARD_MIN = 64
local BOARD_ROW = 34

-- Colours from docs/ui-style.md: the note card (#1f1d1a, border #36322c,
-- hover #6b624f), note text #e6e6e6, and the idle status dot #7a7a7a.
local CARD_BG = { 0x1f / 255, 0x1d / 255, 0x1a / 255 }
local CARD_BORDER = { 0x36 / 255, 0x32 / 255, 0x2c / 255 }
local CARD_HOVER = { 0x6b / 255, 0x62 / 255, 0x4f / 255 }
local NOTE_TEXT = { 0.9, 0.9, 0.9 }
local IDLE_DOT = { 0x7a / 255, 0x7a / 255, 0x7a / 255 }
local CARD_BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	edgeSize = 1,
}

local frame, ui

local function addon()
	return ns.Corkboard
end

local function store()
	return addon().store
end

local function myRealm()
	return View.realmOf(store().env.me)
end

local function now()
	return store().env.now()
end

local function retain()
	return ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
end

local function button(parent, text, width)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	return b
end

local function tooltip(owner, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(text)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

-- A ScrollBox list with the minimal scrollbar, which hides when not needed.
local function scrollList(parent, initializer, template)
	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementInitializer(template, initializer)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
	if ScrollUtil.AddManagedScrollBarVisibilityBehavior then
		ScrollUtil.AddManagedScrollBarVisibilityBehavior(box, bar)
	end
	return box, view
end

-- Board list ------------------------------------------------------------------

local function initBoard(row, board)
	if not row.name then
		row.selected = row:CreateTexture(nil, "BACKGROUND")
		row.selected:SetAllPoints()
		row.selected:SetColorTexture(1, 0.82, 0, 0.08) -- the mockup's gold wash
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("TOPLEFT", 8, -4)
		row.name:SetPoint("TOPRIGHT", -6, -4)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row:SetScript("OnClick", function(self)
			Main:SelectBoard(self.boardId)
		end)
	end
	local current = store():current()
	row.boardId = board.id
	row.name:SetText(Store.name(board))
	row.detail:SetText(View.boardDetail(#Store.notes(board)))
	row.selected:SetShown(current ~= nil and current.id == board.id)
end

-- Note cards --------------------------------------------------------------------

local function cardEnter(card)
	card:SetBackdropBorderColor(unpack(CARD_HOVER))
	card.age:Hide()
	card.edit:Show()
	card.delete:Show()
end

local function cardLeave(card)
	if card:IsMouseOver() then
		return -- moved onto its own Edit or Delete button
	end
	card:SetBackdropBorderColor(unpack(CARD_BORDER))
	card.age:Show()
	card.edit:Hide()
	card.delete:Hide()
end

local function iconButton(card, texture, label, onClick)
	local b = CreateFrame("Button", nil, card)
	b:SetSize(16, 16)
	b:SetNormalTexture(texture)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", function()
		onClick(card.boardId, card.noteId)
	end)
	tooltip(b, label)
	b:HookScript("OnLeave", function()
		cardLeave(card)
	end)
	b:Hide()
	return b
end

local function makeCard(row, column)
	local card = CreateFrame("Frame", nil, row, "BackdropTemplate")
	if column == 1 then
		card:SetPoint("TOPLEFT")
		card:SetPoint("BOTTOMRIGHT", row, "BOTTOM", -CARD_GAP / 2, CARD_GAP)
	else
		card:SetPoint("TOPRIGHT")
		card:SetPoint("BOTTOMLEFT", row, "BOTTOM", CARD_GAP / 2, CARD_GAP)
	end
	card:SetBackdrop(CARD_BACKDROP)
	card:SetBackdropColor(unpack(CARD_BG))
	card:SetBackdropBorderColor(unpack(CARD_BORDER))
	card:EnableMouse(true)
	card:SetScript("OnEnter", cardEnter)
	card:SetScript("OnLeave", cardLeave)
	ns.Links.Enable(card)

	card.tagBorder = card:CreateTexture(nil, "ARTWORK")
	card.tagBorder:SetSize(10, 10)
	card.tagBorder:SetPoint("TOPLEFT", CARD_PAD, -CARD_PAD - 1)
	card.tagBorder:SetColorTexture(0, 0, 0)
	card.tag = card:CreateTexture(nil, "OVERLAY")
	card.tag:SetSize(8, 8)
	card.tag:SetPoint("CENTER", card.tagBorder)

	card.age = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.age:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD)
	card.byline = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.byline:SetPoint("LEFT", card.tagBorder, "RIGHT", 6, 0)
	card.byline:SetWidth(CARD_WIDTH - 2 * CARD_PAD - 16 - 44) -- leaves room for the age or buttons
	card.byline:SetJustifyH("LEFT")
	card.byline:SetWordWrap(false)

	card.delete = iconButton(card, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Delete note", function(boardId, noteId)
		ns.Popups.DeleteNote(boardId, noteId)
	end)
	card.delete:SetPoint("TOPRIGHT", -CARD_PAD + 2, -CARD_PAD + 3)
	card.edit = iconButton(card, "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "Edit note", function(boardId, noteId)
		ns.Editor:Open(boardId, noteId)
	end)
	card.edit:SetPoint("RIGHT", card.delete, "LEFT", -4, 0)

	card.text = card:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	card.text:SetPoint("TOPLEFT", CARD_PAD, -(CARD_PAD + CARD_HEADER + 5))
	card.text:SetPoint("TOPRIGHT", -CARD_PAD, -(CARD_PAD + CARD_HEADER + 5))
	card.text:SetJustifyH("LEFT")
	card.text:SetJustifyV("TOP")
	card.text:SetWordWrap(true)
	card.text:SetNonSpaceWrap(true)
	card.text:SetTextColor(unpack(NOTE_TEXT))
	return card
end

local function fillCard(card, boardId, note)
	card.boardId, card.noteId = boardId, note.id
	card.tag:SetColorTexture(unpack(View.tag(note.color).color))
	card.byline:SetText(View.byline(note, myRealm()))
	card.age:SetText(View.shortAge(now() - note.rev))
	card.text:SetText(note.text)
	card:SetBackdropBorderColor(unpack(CARD_BORDER))
	card.age:Show()
	card.edit:Hide()
	card.delete:Hide()
	card:Show()
end

-- One element per row of cards; the row's height is its tallest card's.
local function initRow(row, data)
	row.cards = row.cards or {}
	for column = 1, View.COLUMNS do
		local card = row.cards[column] or makeCard(row, column)
		row.cards[column] = card
		local note = data.notes[column]
		if note then
			fillCard(card, data.boardId, note)
		else
			card:Hide()
		end
	end
end

local function cardHeight(note)
	ui.measure:SetText(note.text)
	local height = CARD_PAD + CARD_HEADER + 5 + ui.measure:GetStringHeight() + CARD_PAD
	return math.max(CARD_MIN, math.ceil(height))
end

local function noteRows(boardId, notes)
	local rows = {}
	for i, cards in ipairs(View.rows(notes)) do
		local height = 0
		for _, note in ipairs(cards) do
			height = math.max(height, cardHeight(note))
		end
		rows[i] = { boardId = boardId, notes = cards, height = height + CARD_GAP }
	end
	return rows
end

-- The window ----------------------------------------------------------------------

local function build()
	frame = CreateFrame("Frame", "CorkboardFrame", UIParent, "PortraitFrameTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	if frame.SetTitle then
		frame:SetTitle("Corkboard")
	end
	if frame.SetPortraitToAsset then
		frame:SetPortraitToAsset(Main.ICON)
	end
	table.insert(UISpecialFrames, "CorkboardFrame") -- Escape closes it
	frame:Hide()
	ui = {}

	-- Header: board name, search, New Note.
	ui.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	ui.title:SetPoint("TOPLEFT", 64, -34)
	ui.title:SetJustifyH("LEFT")
	ui.title:SetWordWrap(false)
	ui.newNote = button(frame, "New Note", 100)
	ui.newNote:SetPoint("TOPRIGHT", -MARGIN, -30)
	ui.newNote:SetScript("OnClick", function()
		local board = store():current()
		if board then
			ns.Editor:Open(board.id)
		end
	end)
	ui.search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
	ui.search:SetSize(180, 20)
	ui.search:SetPoint("RIGHT", ui.newNote, "LEFT", -10, 0)
	ui.search:SetAutoFocus(false)
	ui.search:HookScript("OnTextChanged", function()
		Main:Refresh()
	end)
	ui.title:SetWidth(WIDTH - 64 - MARGIN - 100 - 10 - 180 - 20) -- up to the search box

	-- Board list.
	local list = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	list:SetPoint("TOPLEFT", MARGIN, -62)
	list:SetPoint("BOTTOMLEFT", MARGIN, 30)
	list:SetWidth(LIST_WIDTH)
	local heading = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("TOPLEFT", 10, -8)
	heading:SetText("Boards")
	local boardView
	ui.boards, boardView = scrollList(list, initBoard, "Button")
	boardView:SetElementExtent(BOARD_ROW)
	ui.boards:SetPoint("TOPLEFT", 4, -26)
	ui.boards:SetPoint("BOTTOMRIGHT", -16, 32)
	local third = (LIST_WIDTH - 16) / 3
	ui.newBoard = button(list, "New", third)
	ui.newBoard:SetPoint("BOTTOMLEFT", 6, 6)
	ui.newBoard:SetScript("OnClick", function()
		ns.Popups.NewBoard()
	end)
	ui.rename = button(list, "Rename", third)
	ui.rename:SetPoint("LEFT", ui.newBoard, "RIGHT", 2, 0)
	ui.rename:SetScript("OnClick", function()
		local board = store():current()
		if board then
			ns.Popups.RenameBoard(board.id)
		end
	end)
	ui.delete = button(list, "Delete", third)
	ui.delete:SetPoint("LEFT", ui.rename, "RIGHT", 2, 0)
	ui.delete:SetScript("OnClick", function()
		local board = store():current()
		if board then
			ns.Popups.DeleteBoard(board.id)
		end
	end)

	-- Note grid.
	local notes = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	notes:SetPoint("TOPLEFT", list, "TOPRIGHT", GAP, 0)
	notes:SetPoint("BOTTOMRIGHT", -MARGIN, 30)
	local noteView
	ui.notes, noteView = scrollList(notes, initRow, "Frame")
	noteView:SetElementExtentCalculator(function(_, data)
		return data.height
	end)
	ui.notes:SetPoint("TOPLEFT", INSET_PAD, -INSET_PAD)
	ui.notes:SetPoint("BOTTOMRIGHT", -INSET_PAD - SCROLLBAR, INSET_PAD)
	ui.empty = notes:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.empty:SetPoint("CENTER")
	ui.measure = notes:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	ui.measure:SetWidth(CARD_TEXT_WIDTH)
	ui.measure:SetWordWrap(true)
	ui.measure:SetNonSpaceWrap(true)
	ui.measure:Hide()

	-- Status line.
	ui.dot = frame:CreateTexture(nil, "OVERLAY")
	ui.dot:SetSize(6, 6)
	ui.dot:SetPoint("BOTTOMLEFT", 16, 12)
	ui.dot:SetColorTexture(unpack(IDLE_DOT))
	ui.status = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.status:SetPoint("LEFT", ui.dot, "RIGHT", 6, 0)
	ui.count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.count:SetPoint("BOTTOMRIGHT", -16, 10)

	frame:SetScript("OnShow", function()
		Main:Refresh()
		-- Keeps the card ages current while the window is open.
		ui.ticker = C_Timer.NewTicker(30, function()
			Main:Refresh()
		end)
	end)
	frame:SetScript("OnHide", function()
		if ui.ticker then
			ui.ticker:Cancel()
			ui.ticker = nil
		end
		ns.Editor:Close()
	end)
end

function Main:Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	local boards = store():boards()
	local current = store():current()
	if not current and boards[1] then
		current = store():select(boards[1].id)
	end
	ui.boards:SetDataProvider(CreateDataProvider(boards), retain())

	ui.title:SetText(current and Store.name(current) or "")
	ui.newNote:SetEnabled(current ~= nil)
	ui.rename:SetEnabled(current ~= nil)
	ui.delete:SetEnabled(current ~= nil)

	local all = current and Store.notes(current) or {}
	local shown = View.filter(all, ui.search:GetText())
	ui.notes:SetDataProvider(CreateDataProvider(current and noteRows(current.id, shown) or {}), retain())
	if not current then
		ui.empty:SetText("No boards yet. Click New to make one.")
	elseif #all == 0 then
		ui.empty:SetText("No notes yet. Click New Note to add one.")
	elseif #shown == 0 then
		ui.empty:SetText("No notes match your search.")
	else
		ui.empty:SetText("")
	end
	local status, count = View.status(#all, #shown)
	ui.status:SetText(status)
	ui.count:SetText(current and count or "")
end

function Main:SelectBoard(id)
	store():select(id)
	self:Refresh()
end

function Main:Toggle()
	if not frame then
		build()
	end
	frame:SetShown(not frame:IsShown())
end
