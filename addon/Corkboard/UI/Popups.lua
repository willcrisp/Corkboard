-- Confirmations and name prompts, as StaticPopups (docs/ui-style.md).

local _, ns = ...
local Store = ns.Store

local Popups = {}
ns.Popups = Popups

local function store()
	return ns.Corkboard.store
end

-- The dialog's edit box. Its field name has changed between client
-- versions, so look for each.
local function editBoxOf(dialog)
	return dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox())
end

-- The StaticPopup dialog a child frame (such as its edit box) belongs to.
local function dialogOf(frame)
	while frame and not frame.which do
		frame = frame:GetParent()
	end
	return frame
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A named prompt: on Enter or the accept button, `accept(text, data)` runs,
-- and the dialog stays open while it returns false.
local function namePrompt(text, acceptLabel, accept, maxLetters)
	return {
		text = text,
		button1 = acceptLabel,
		button2 = CANCEL or "Cancel",
		hasEditBox = true,
		maxLetters = maxLetters or 64,
		OnShow = function(self, data)
			local editBox = editBoxOf(self)
			editBox:SetText(data and data.name or "")
			editBox:HighlightText()
			editBox:SetFocus()
		end,
		OnAccept = function(self, data)
			return not accept(editBoxOf(self):GetText(), data) -- true keeps the dialog open
		end,
		EditBoxOnEnterPressed = function(editBox, data)
			if accept(editBox:GetText(), data) then
				dialogOf(editBox):Hide()
			end
		end,
		EditBoxOnEscapePressed = function(editBox)
			dialogOf(editBox):Hide()
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

local function done(ok, reason)
	if not ok then
		ns.Corkboard:Warn(ns.Commands.explain(reason))
		return false
	end
	ns.Corkboard:Changed()
	return true
end

StaticPopupDialogs.CORKBOARD_NEW_BOARD = namePrompt("Name the new board:", "Create", function(name)
	return done(store():createBoard(trim(name)))
end)

StaticPopupDialogs.CORKBOARD_RENAME_BOARD = namePrompt("Rename the board:", "Rename", function(name, data)
	return done(store():renameBoard(data.boardId, trim(name)))
end)

StaticPopupDialogs.CORKBOARD_DELETE_BOARD = {
	text = "Delete the board \"%s\" and its %s from this account?\n\nOther members keep their copies.",
	button1 = DELETE or "Delete",
	button2 = CANCEL or "Cancel",
	OnAccept = function(_, data)
		done(store():deleteBoard(data.boardId))
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs.CORKBOARD_DELETE_NOTE = {
	text = "Delete this note?",
	button1 = DELETE or "Delete",
	button2 = CANCEL or "Cancel",
	OnAccept = function(_, data)
		if done(store():deleteNote(data.boardId, data.noteId)) then
			ns.Editor:Close()
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs.CORKBOARD_JOIN = namePrompt("Paste a Corkboard invite to join a board.", "Join", function(text)
	local board, new = store():joinBoard(trim(text))
	if not board then
		ns.Corkboard:Warn(ns.Commands.explain(new))
		return false
	end
	if new then
		ns.Corkboard:Print(("Joined %s. Its notes arrive when another member is online."):format(Store.name(board)))
	else
		ns.Corkboard:Print(("You're already on %s. Its invite is up to date."):format(Store.name(board)))
	end
	ns.Corkboard:Changed()
	return true
end, 200)

StaticPopupDialogs.CORKBOARD_REMOVE_MEMBER = {
	text = "Remove %s from %s?\n\nThis rotates the secret. Everyone you keep will need the new invite.",
	button1 = "Remove",
	button2 = CANCEL or "Cancel",
	OnAccept = function(_, data)
		done(store():removeMember(data.boardId, data.name))
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs.CORKBOARD_ROTATE_SECRET = {
	text = "Give %s a new secret?\n\nEveryone on the board will need the new invite, and anyone without it is cut off.",
	button1 = "Rotate",
	button2 = CANCEL or "Cancel",
	OnAccept = function(_, data)
		done(store():rotateSecret(data.boardId))
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs.CORKBOARD_EXPIRED = {
	text = "%s: that invite is out of date. Ask the board owner for a new one.",
	button1 = OKAY or "Okay",
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function Popups.Join()
	StaticPopup_Show("CORKBOARD_JOIN")
end

function Popups.RemoveMember(boardId, name)
	local board = store():board(boardId)
	if board then
		StaticPopup_Show("CORKBOARD_REMOVE_MEMBER", ns.View.shortName(name, ns.View.realmOf(store().env.me)),
			Store.name(board), { boardId = boardId, name = name })
	end
end

function Popups.RotateSecret(boardId)
	local board = store():board(boardId)
	if board then
		StaticPopup_Show("CORKBOARD_ROTATE_SECRET", Store.name(board), nil, { boardId = boardId })
	end
end

function Popups.Expired(boardId)
	local board = store():board(boardId)
	if board then
		StaticPopup_Show("CORKBOARD_EXPIRED", Store.name(board), nil, { boardId = boardId })
	end
end

function Popups.NewBoard()
	StaticPopup_Show("CORKBOARD_NEW_BOARD")
end

function Popups.RenameBoard(boardId)
	local board = store():board(boardId)
	if board then
		StaticPopup_Show("CORKBOARD_RENAME_BOARD", nil, nil, { boardId = boardId, name = Store.name(board) })
	end
end

function Popups.DeleteBoard(boardId)
	local board = store():board(boardId)
	if board then
		local detail = ns.View.boardDetail(#Store.notes(board))
		StaticPopup_Show("CORKBOARD_DELETE_BOARD", Store.name(board), detail, { boardId = boardId })
	end
end

function Popups.DeleteNote(boardId, noteId)
	StaticPopup_Show("CORKBOARD_DELETE_NOTE", nil, nil, { boardId = boardId, noteId = noteId })
end
