-- The note editor (docs/ui-style.md "Note editor", docs/mockups/Editor.dc.html):
-- a multi-line input that takes shift-clicked links, a byte counter, a tag
-- picker, and Delete / Cancel / Save. Save stays disabled while the text is
-- something a peer's sanitiser would drop (§6).

local _, ns = ...
local button = ns.Main.Button
local View, Store = ns.View, ns.Store

local Editor = {}
ns.Editor = Editor

local WIDTH, HEIGHT = 460, 330
local PAD = 14
local SWATCH = 18
local WARNING = { 1, 1, 0 } -- warnings are yellow (docs/ui-style.md)
local GOLD = { 1, 0.82, 0 } -- NORMAL_FONT_COLOR: marks the chosen tag

local frame, ui
local state = {} -- boardId, noteId (nil for a new note), color

local function store()
	return ns.Corkboard.store
end

-- The note being edited, or nil for a new one (or one deleted meanwhile).
local function editing()
	local board = store():board(state.boardId)
	local note = board and state.noteId and board.notes[state.noteId]
	if note and note.deleted then
		return board, nil
	end
	return board, note
end

local function setColor(color)
	state.color = color
	for i, swatch in ipairs(ui.swatches) do
		swatch.ring:SetShown(i == color)
	end
	ui.tagName:SetText(View.tag(color).name)
end

local function validate()
	local text = ui.edit:GetText()
	local counter, over = View.counter(text)
	ui.counter:SetText(counter)
	if over then
		ui.counter:SetTextColor(unpack(WARNING))
	else
		ui.counter:SetTextColor(0.62, 0.62, 0.62)
	end
	local ok, message = View.check(text)
	-- An empty note just can't be saved yet; that's not worth a warning.
	ui.message:SetText((ok or text == "") and "" or message)
	ui.save:SetEnabled(ok)
	return ok
end

local function swatchButton(index)
	local tag = View.TAGS[index]
	local b = CreateFrame("Button", nil, frame)
	b:SetSize(SWATCH, SWATCH)
	b.ring = b:CreateTexture(nil, "BACKGROUND")
	b.ring:SetPoint("TOPLEFT", -2, 2)
	b.ring:SetPoint("BOTTOMRIGHT", 2, -2)
	b.ring:SetColorTexture(unpack(GOLD))
	local border = b:CreateTexture(nil, "BORDER")
	border:SetAllPoints()
	border:SetColorTexture(0, 0, 0)
	local fill = b:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", -1, 1)
	fill:SetColorTexture(unpack(tag.color))
	b:SetScript("OnClick", function()
		setColor(index)
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(tag.name)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return b
end

local function build()
	frame = CreateFrame("Frame", "CorkboardEditor", UIParent, "ButtonFrameTemplate")
	if ButtonFrameTemplate_HidePortrait then
		ButtonFrameTemplate_HidePortrait(frame)
	end
	if ButtonFrameTemplate_HideButtonBar then
		ButtonFrameTemplate_HideButtonBar(frame)
	end
	if frame.Inset then
		frame.Inset:Hide()
	end
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER", 0, 40)
	frame:SetFrameStrata("HIGH") -- above the board window, below its StaticPopups
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	table.insert(UISpecialFrames, "CorkboardEditor")
	frame:Hide()
	ui = {}

	ui.header = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.header:SetPoint("TOPLEFT", PAD, -32)
	ui.header:SetWidth(WIDTH - 2 * PAD)
	ui.header:SetJustifyH("LEFT")
	ui.header:SetWordWrap(false)
	local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", PAD, -52)
	label:SetText("Note")

	-- The text box: an inset holding a scroll frame around a multi-line EditBox.
	local box = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	box:SetPoint("TOPLEFT", PAD - 2, -68)
	box:SetPoint("TOPRIGHT", -PAD + 2, -68)
	box:SetHeight(150)
	local scroll = CreateFrame("ScrollFrame", "CorkboardEditorScroll", box, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)
	ui.edit = CreateFrame("EditBox", "CorkboardEditorText", scroll)
	ui.edit:SetMultiLine(true)
	ui.edit:SetAutoFocus(false)
	ui.edit:SetFontObject(ChatFontNormal)
	ui.edit:SetWidth(WIDTH - 2 * PAD - 32)
	ui.edit:SetMaxLetters(0)
	ui.edit:SetScript("OnEscapePressed", ui.edit.ClearFocus)
	ui.edit:SetScript("OnTextChanged", validate)
	ui.edit:SetScript("OnReceiveDrag", ns.Links.OnReceiveDrag)
	ui.edit:SetScript("OnMouseDown", ns.Links.OnReceiveDrag)
	if ScrollingEdit_OnCursorChanged and ScrollingEdit_OnUpdate then -- keeps the cursor in view
		ui.edit:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
		ui.edit:SetScript("OnUpdate", function(self, elapsed)
			ScrollingEdit_OnUpdate(self, elapsed, scroll)
		end)
	end
	scroll:SetScrollChild(ui.edit)
	-- Clicks anywhere in the inset (including the empty space below the last
	-- line) focus the note, with the cursor at the end of the text.
	ui.edit:SetHeight(150 - 12)
	scroll:SetScript("OnSizeChanged", function(_, _, height)
		ui.edit:SetHeight(height)
	end)
	local function focusAtEnd()
		ui.edit:SetFocus()
		ui.edit:SetCursorPosition(#(ui.edit:GetText() or ""))
	end
	box:EnableMouse(true)
	box:SetScript("OnMouseDown", focusAtEnd)
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", focusAtEnd)
	ns.Links.HookInsert(ui.edit)

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -4)
	hint:SetText("Shift-click items, quests or spells to link them")
	ui.counter = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.counter:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", -2, -4)
	ui.message = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.message:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
	ui.message:SetWidth(WIDTH - 2 * PAD)
	ui.message:SetJustifyH("LEFT")
	ui.message:SetTextColor(unpack(WARNING))

	-- Tag picker.
	local tagLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	tagLabel:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -44)
	tagLabel:SetText("Tag")
	ui.swatches = {}
	for i = 1, #View.TAGS do
		local swatch = swatchButton(i)
		if i == 1 then
			swatch:SetPoint("LEFT", tagLabel, "RIGHT", 10, 0)
		else
			swatch:SetPoint("LEFT", ui.swatches[i - 1], "RIGHT", 7, 0)
		end
		ui.swatches[i] = swatch
	end
	ui.tagName = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.tagName:SetPoint("LEFT", ui.swatches[#ui.swatches], "RIGHT", 10, 0)

	-- Buttons.
	ui.delete = button(frame, DELETE or "Delete", 90)
	ui.delete:SetPoint("BOTTOMLEFT", PAD - 2, 12)
	ui.delete:SetScript("OnClick", function()
		ns.Popups.DeleteNote(state.boardId, state.noteId)
	end)
	ui.save = button(frame, SAVE or "Save", 90)
	ui.save:SetPoint("BOTTOMRIGHT", -PAD + 2, 12)
	ui.save:SetScript("OnClick", function()
		Editor:Save()
	end)
	local cancel = button(frame, CANCEL or "Cancel", 90)
	cancel:SetPoint("RIGHT", ui.save, "LEFT", -6, 0)
	cancel:SetScript("OnClick", function()
		Editor:Close()
	end)
end

-- Opens the editor on a note, or on a new note when noteId is nil.
function Editor:Open(boardId, noteId)
	if not frame then
		build()
	end
	state = { boardId = boardId, noteId = noteId }
	local board, note = editing()
	if not board or (noteId and not note) then
		return
	end
	if frame.SetTitle then
		frame:SetTitle(note and "Edit Note" or "New Note")
	end
	ui.header:SetText(View.editorHeader(Store.name(board), note, store().env.now(), View.realmOf(store().env.me)))
	ui.edit:SetText(note and note.text or "")
	ui.delete:SetShown(note ~= nil)
	setColor(note and note.color or 1)
	validate()
	frame:Show()
	ui.edit:SetFocus()
end

function Editor:Close()
	if frame then
		frame:Hide()
	end
end

-- Saves through the store. Returns true when the editor closed.
function Editor:Save()
	if not validate() then
		return false
	end
	local text = ui.edit:GetText()
	local board, note = editing()
	local ok, reason = true, nil
	if not board then
		ok, reason = nil, "missing"
	elseif state.noteId and not note then
		ok, reason = nil, "deleted"
	elseif note then
		local changes = View.changes(note, text, state.color)
		if changes then
			ok, reason = store():editNote(board.id, note.id, changes)
		end
	else
		ok, reason = store():addNote(board.id, text, state.color)
	end
	if not ok then
		ui.message:SetText(ns.Commands.explain(reason))
		return false
	end
	self:Close()
	ns.Corkboard:Changed()
	return true
end
