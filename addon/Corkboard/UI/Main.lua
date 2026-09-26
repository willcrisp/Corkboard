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
local FOOTER = 58 -- two rows of board-list buttons

-- Colours from docs/ui-style.md: the note card (#1f1d1a, border #36322c,
-- hover #6b624f), note text #e6e6e6, and the idle status dot #7a7a7a.
local CARD_BG = { 0x1f / 255, 0x1d / 255, 0x1a / 255 }
local CARD_BORDER = { 0x36 / 255, 0x32 / 255, 0x2c / 255 }
local CARD_HOVER = { 0x6b / 255, 0x62 / 255, 0x4f / 255 }
local NOTE_TEXT = { 0.9, 0.9, 0.9 }
local FRAME_BG = { 0x1b / 255, 0x1a / 255, 0x18 / 255 } -- fills a hollow status dot
local LEAD = { 0.9, 0.9, 0.9 }
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }
local WARNING = { 1, 1, 0 }
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

local function sync()
	return addon().sync
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
	return box, view, bar
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
	row.detail:SetText(View.boardDetail(#Store.notes(board), #sync():onlineNames(board.id)))
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
	ui.boards:SetPoint("BOTTOMRIGHT", -16, FOOTER + 4)
	local half = (LIST_WIDTH - 14) / 2
	ui.newBoard = button(list, "New", half)
	ui.newBoard:SetPoint("BOTTOMLEFT", 6, 32)
	ui.newBoard:SetScript("OnClick", function()
		ns.Popups.NewBoard()
	end)
	ui.join = button(list, "Join", half)
	ui.join:SetPoint("LEFT", ui.newBoard, "RIGHT", 2, 0)
	ui.join:SetScript("OnClick", function()
		ns.Popups.Join()
	end)
	ui.rename = button(list, "Rename", half)
	ui.rename:SetPoint("BOTTOMLEFT", 6, 6)
	ui.rename:SetScript("OnClick", function()
		local board = store():current()
		if board then
			ns.Popups.RenameBoard(board.id)
		end
	end)
	ui.delete = button(list, "Delete", half)
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
	ui.notesPanel = notes
	local noteView
	ui.notes, noteView, ui.notesBar = scrollList(notes, initRow, "Frame")
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

	-- The alert strip (docs/mockups/SyncStates): yellow text over the notes
	-- when a board is far behind or its sends are paused.
	ui.alert = CreateFrame("Frame", nil, notes)
	ui.alert:SetPoint("BOTTOMLEFT", INSET_PAD, INSET_PAD)
	ui.alert:SetPoint("BOTTOMRIGHT", -INSET_PAD, INSET_PAD)
	ui.alert:SetHeight(26)
	local strip = ui.alert:CreateTexture(nil, "BACKGROUND")
	strip:SetAllPoints()
	strip:SetColorTexture(0, 0, 0, 0.6)
	ui.alertText = ui.alert:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.alertText:SetPoint("LEFT", 8, 0)
	ui.alertText:SetTextColor(unpack(WARNING))
	ui.reload = button(ui.alert, "Reload", 70)
	ui.reload:SetPoint("RIGHT", -4, 0)
	ui.reload:SetScript("OnClick", function()
		ReloadUI()
	end)
	ui.alert:Hide()

	-- Status line: a dot (hollow while in progress or idle), the state, and
	-- the note count.
	ui.dot = frame:CreateTexture(nil, "ARTWORK")
	ui.dot:SetSize(6, 6)
	ui.dot:SetPoint("BOTTOMLEFT", 16, 12)
	ui.hole = frame:CreateTexture(nil, "OVERLAY")
	ui.hole:SetSize(4, 4)
	ui.hole:SetPoint("CENTER", ui.dot)
	ui.hole:SetColorTexture(unpack(FRAME_BG))
	ui.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.status:SetPoint("LEFT", ui.dot, "RIGHT", 6, 0)
	ui.detail = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.detail:SetPoint("LEFT", ui.status, "RIGHT", 4, 0)
	ui.count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.count:SetPoint("BOTTOMRIGHT", -16, 10)

	-- Bottom tabs: Notes and Members (docs/ui-style.md).
	ui.tabs = {}
	for i, label in ipairs({ "Notes", "Members" }) do
		local ok, tab = pcall(CreateFrame, "Button", "CorkboardFrameTab" .. i, frame, "PanelTabButtonTemplate")
		if not ok then
			tab = CreateFrame("Button", "CorkboardFrameTab" .. i, frame, "CharacterFrameTabButtonTemplate")
		end
		tab:SetID(i)
		tab:SetText(label)
		if i == 1 then
			tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
		else
			tab:SetPoint("LEFT", ui.tabs[i - 1], "RIGHT", 4, 0)
		end
		tab:SetScript("OnClick", function()
			Main:ShowTab(i)
		end)
		if PanelTemplates_TabResize then
			PanelTemplates_TabResize(tab, 0)
		end
		ui.tabs[i] = tab
	end
	if PanelTemplates_SetNumTabs then
		PanelTemplates_SetNumTabs(frame, #ui.tabs)
	end
	ui.members = ns.Members:Build(notes)
	ui.tab = 1

	frame:SetScript("OnShow", function()
		Main:ShowTab(ui.tab)
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

local function setStatus(state)
	local color = View.DOTS[state.dot]
	ui.dot:SetColorTexture(unpack(color))
	ui.hole:SetShown(state.hollow == true)
	ui.status:SetText(state.label)
	ui.status:SetTextColor(unpack(state.dim and DIM or LEAD))
	ui.detail:SetText(state.detail or "")
end

local function setAlert(status)
	local text
	if status.behind then
		text = ("%d notes behind. The companion will fetch the rest, then /reload."):format(status.behind)
	elseif status.paused and status.queued > 0 then
		text = ("Sync paused. %d queued messages will send when it's allowed again."):format(status.queued)
	end
	ui.alert:SetShown(text ~= nil)
	ui.alertText:SetText(text or "")
	ui.reload:SetShown(status.behind ~= nil)
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
	ui.tabs[2]:SetEnabled(current ~= nil)

	local all = current and Store.notes(current) or {}
	local shown = View.filter(all, ui.search:GetText())
	ui.notes:SetDataProvider(CreateDataProvider(current and noteRows(current.id, shown) or {}), retain())
	if not current then
		ui.empty:SetText("No boards yet. Click New to make one, or Join to use an invite.")
	elseif #all == 0 then
		ui.empty:SetText("No notes yet. Click New Note to add one.")
	elseif #shown == 0 then
		ui.empty:SetText("No notes match your search.")
	else
		ui.empty:SetText("")
	end
	if current then
		local status = sync():status(current.id)
		setStatus(View.syncStatus(status, ns.Net:ChannelState(current), now(), myRealm()))
		setAlert(status)
		ui.count:SetText(View.count(#all, #shown))
	else
		setStatus({ label = "", dot = "idle", hollow = true })
		ui.alert:Hide()
		ui.count:SetText("")
	end
	if ui.tab == 2 then
		ns.Members:Refresh(current)
	end
end

-- Tab 1 is the notes; tab 2 the members, invite and sync options.
function Main:ShowTab(index)
	if index == 2 and not store():current() then
		index = 1
	end
	ui.tab = index
	if PanelTemplates_SetTab then
		PanelTemplates_SetTab(frame, index)
	end
	ui.notes:SetShown(index == 1)
	ui.notesBar:SetShown(index == 1)
	ui.search:SetShown(index == 1)
	ui.newNote:SetShown(index == 1)
	ui.empty:SetShown(index == 1)
	ui.members:SetShown(index == 2)
	if index ~= 1 then
		ui.alert:Hide()
	end
	self:Refresh()
end

function Main:SelectBoard(id)
	local board = store():select(id)
	if board then
		board.sync = board.sync or {}
		board.sync.lastUsed = now() -- the most recently used boards keep their channels
		ns.Net:Refresh()
	end
	self:Refresh()
end

function Main:IsShown()
	return frame ~= nil and frame:IsShown()
end

function Main:Toggle()
	if not frame then
		build()
	end
	frame:SetShown(not frame:IsShown())
end
