-- The player note editor (docs/design.md §9.4): a character's name (typed,
-- or taken from the target), Avoid or Good player, and why, with
-- shift-clicked links. Built like the note editor, and Save likewise stays
-- disabled while the entry is something a peer's sanitiser would drop.

local _, ns = ...
local button = ns.Main.Button
local View, Store, Players = ns.View, ns.Store, ns.Players

local PlayerEditor = {}
ns.PlayerEditor = PlayerEditor

local WIDTH, HEIGHT = 440, 340
local PAD = 14
local WARNING = { 1, 1, 0 } -- warnings are yellow (docs/ui-style.md)

local frame, ui
local state = {} -- boardId, noteId (nil for a new entry), verdict

local function store()
	return ns.Corkboard.store
end

-- The entry being edited, or nil for a new one (or one deleted meanwhile).
local function editing()
	local board = store():board(state.boardId)
	local note = board and state.noteId and board.notes[state.noteId]
	if note and (note.deleted or note.kind ~= Players.KIND) then
		return board, nil
	end
	return board, note
end

local function validate()
	local name, reason = ui.name:GetText(), ui.reason:GetText()
	local counter, over = View.playerCounter(name, state.verdict, reason)
	ui.counter:SetText(counter)
	if over then
		ui.counter:SetTextColor(unpack(WARNING))
	else
		ui.counter:SetTextColor(0.62, 0.62, 0.62)
	end
	local ok, message = View.checkPlayer(name, state.verdict, reason)
	ui.message:SetText(message or "")
	ui.save:SetEnabled(ok)
	return ok
end

local function setVerdict(verdict)
	state.verdict = verdict
	ui.avoid:SetChecked(verdict == "avoid")
	ui.good:SetChecked(verdict == "good")
	validate()
end

local function radio(label, verdict)
	local box = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
	box.label:SetText(label)
	box:SetScript("OnClick", function()
		setVerdict(verdict)
	end)
	return box
end

-- Fills the name from the current target. Returns whether there was one.
local function useTarget()
	local name = ns.Corkboard:UnitPlayerName("target")
	if not name then
		return false
	end
	ui.name:SetText(name)
	return true
end

local function build()
	frame = CreateFrame("Frame", "CorkboardPlayerEditor", UIParent, "ButtonFrameTemplate")
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
	table.insert(UISpecialFrames, "CorkboardPlayerEditor")
	frame:Hide()
	ui = {}

	ui.header = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.header:SetPoint("TOPLEFT", PAD, -32)
	ui.header:SetWidth(WIDTH - 2 * PAD)
	ui.header:SetJustifyH("LEFT")
	ui.header:SetWordWrap(false)

	-- The character: typed, or from the target.
	local nameLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", PAD, -56)
	nameLabel:SetText("Character")
	ui.name = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	ui.name:SetSize(220, 20)
	ui.name:SetPoint("LEFT", nameLabel, "RIGHT", 14, 0)
	ui.name:SetAutoFocus(false)
	ui.name:SetMaxBytes(Players.MAX_NAME + 1)
	ui.name:SetScript("OnTextChanged", validate)
	ui.name:SetScript("OnEscapePressed", ui.name.ClearFocus)
	ui.name:SetScript("OnEnterPressed", function()
		ui.reason:SetFocus()
	end)
	ui.name:SetScript("OnTabPressed", function()
		ui.reason:SetFocus()
	end)
	ui.target = button(frame, "Target", 70)
	ui.target:SetPoint("LEFT", ui.name, "RIGHT", 8, 0)
	ui.target:SetScript("OnClick", function()
		if not useTarget() then
			ui.message:SetText("Target a player first.")
		end
	end)

	-- The verdict.
	ui.avoid = radio("Avoid", "avoid")
	ui.avoid:SetPoint("TOPLEFT", PAD - 4, -80)
	ui.good = radio("Good player", "good")
	ui.good:SetPoint("LEFT", ui.avoid, "RIGHT", 80, 0)

	-- Why: an inset holding a scroll frame around a multi-line EditBox.
	local whyLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	whyLabel:SetPoint("TOPLEFT", PAD, -112)
	whyLabel:SetText("Why")
	local box = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	box:SetPoint("TOPLEFT", PAD - 2, -128)
	box:SetPoint("TOPRIGHT", -PAD + 2, -128)
	box:SetHeight(110)
	local scroll = CreateFrame("ScrollFrame", "CorkboardPlayerEditorScroll", box, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)
	ui.reason = CreateFrame("EditBox", "CorkboardPlayerEditorText", scroll)
	ui.reason:SetMultiLine(true)
	ui.reason:SetAutoFocus(false)
	ui.reason:SetFontObject(ChatFontNormal)
	ui.reason:SetWidth(WIDTH - 2 * PAD - 32)
	ui.reason:SetMaxLetters(0)
	ui.reason:SetScript("OnEscapePressed", ui.reason.ClearFocus)
	ui.reason:SetScript("OnTextChanged", validate)
	ui.reason:SetScript("OnReceiveDrag", ns.Links.OnReceiveDrag)
	ui.reason:SetScript("OnMouseDown", ns.Links.OnReceiveDrag)
	if ScrollingEdit_OnCursorChanged and ScrollingEdit_OnUpdate then -- keeps the cursor in view
		ui.reason:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
		ui.reason:SetScript("OnUpdate", function(self, elapsed)
			ScrollingEdit_OnUpdate(self, elapsed, scroll)
		end)
	end
	scroll:SetScrollChild(ui.reason)
	ui.reason:SetHeight(110 - 12)
	scroll:SetScript("OnSizeChanged", function(_, _, height)
		ui.reason:SetHeight(height)
	end)
	local function focusAtEnd()
		ui.reason:SetFocus()
		ui.reason:SetCursorPosition(#(ui.reason:GetText() or ""))
	end
	box:EnableMouse(true)
	box:SetScript("OnMouseDown", focusAtEnd)
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", focusAtEnd)
	ns.Links.HookInsert(ui.reason)

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -4)
	hint:SetText("What happened? Shift-click items, quests or spells to link them")
	ui.counter = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.counter:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", -2, -4)
	ui.message = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.message:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
	ui.message:SetWidth(WIDTH - 2 * PAD)
	ui.message:SetJustifyH("LEFT")
	ui.message:SetTextColor(unpack(WARNING))

	-- Buttons.
	ui.delete = button(frame, DELETE or "Delete", 90)
	ui.delete:SetPoint("BOTTOMLEFT", PAD - 2, 12)
	ui.delete:SetScript("OnClick", function()
		ns.Popups.DeletePlayer(state.boardId, state.noteId)
	end)
	ui.save = button(frame, SAVE or "Save", 90)
	ui.save:SetPoint("BOTTOMRIGHT", -PAD + 2, 12)
	ui.save:SetScript("OnClick", function()
		PlayerEditor:Save()
	end)
	local cancel = button(frame, CANCEL or "Cancel", 90)
	cancel:SetPoint("RIGHT", ui.save, "LEFT", -6, 0)
	cancel:SetScript("OnClick", function()
		PlayerEditor:Close()
	end)
end

-- Opens the editor on an entry, or on a new one when noteId is nil. A new
-- entry starts with the target's name when a player is targeted.
function PlayerEditor:Open(boardId, noteId)
	if not frame then
		build()
	end
	state = { boardId = boardId, noteId = noteId }
	local board, note = editing()
	if not board or (noteId and not note) then
		return
	end
	local entry = note and Players.decode(note.text)
	if frame.SetTitle then
		frame:SetTitle(note and "Edit Player Note" or "New Player Note")
	end
	local header = View.editorHeader(Store.name(board), note, store().env.now(), View.realmOf(store().env.me))
	ui.header:SetText(note and header or Store.name(board) .. " · new player note")
	ui.name:SetText(entry and entry.name or "")
	if not note then
		useTarget()
	end
	ui.reason:SetText(entry and entry.reason or "")
	ui.delete:SetShown(note ~= nil)
	setVerdict(entry and entry.verdict or "avoid")
	frame:Show()
	if ui.name:GetText() == "" then
		ui.name:SetFocus()
	else
		ui.reason:SetFocus()
	end
end

function PlayerEditor:Close()
	if frame then
		frame:Hide()
	end
end

-- Saves through the store. Returns true when the editor closed.
function PlayerEditor:Save()
	if not validate() then
		return false
	end
	local name, reason = ui.name:GetText(), ui.reason:GetText()
	local board, note = editing()
	local ok, why
	if not board then
		ok, why = nil, "missing"
	elseif state.noteId and not note then
		ok, why = nil, "deleted"
	elseif note then
		ok, why = store():editPlayer(board.id, note.id, name, state.verdict, reason)
	else
		ok, why = store():addPlayer(board.id, name, state.verdict, reason)
	end
	if not ok then
		ui.message:SetText(ns.Commands.explain(why))
		return false
	end
	self:Close()
	ns.Corkboard:Changed()
	return true
end

-- For tests: the fields and buttons.
function PlayerEditor.Widgets()
	return ui
end
