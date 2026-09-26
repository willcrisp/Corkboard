-- Links in notes (docs/design.md §6): hover tooltips, click-through, and
-- shift-click insertion into the note editor.

local _, ns = ...

local Links = {}
ns.Links = Links

-- OnHyperlinkEnter: the game's own tooltip for the link. SetHyperlink raises
-- an error for link types this client can't show, so that case just hides it.
function Links.OnEnter(frame, link)
	GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
	if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then
		GameTooltip:Show()
	else
		GameTooltip:Hide()
	end
end

function Links.OnLeave()
	GameTooltip:Hide()
end

-- OnHyperlinkClick: whatever clicking the link in chat does (item tooltip,
-- shift-click to link it elsewhere, ctrl-click to try it on).
function Links.OnClick(_, link, text, button)
	SetItemRef(link, text, button, DEFAULT_CHAT_FRAME)
end

function Links.Enable(frame)
	frame:SetHyperlinksEnabled(true)
	frame:SetScript("OnHyperlinkEnter", Links.OnEnter)
	frame:SetScript("OnHyperlinkLeave", Links.OnLeave)
	frame:SetScript("OnHyperlinkClick", Links.OnClick)
end

-- Shift-clicking an item, spell or quest goes through the chat link inserter.
-- A post-hook (never a pre-hook) copies the link into `editBox` when it has
-- the focus. Hook one function only: on clients that have both, the old
-- ChatEdit_InsertLink calls ChatFrameUtil.InsertLink, and hooking both
-- would insert twice. Same approach as AceGUI's edit boxes.
function Links.HookInsert(editBox)
	local function insert(link)
		if link and editBox:IsVisible() and editBox:HasFocus() then
			editBox:Insert(link)
		end
	end
	if ChatFrameUtil and ChatFrameUtil.InsertLink then
		hooksecurefunc(ChatFrameUtil, "InsertLink", insert)
	elseif ChatEdit_InsertLink then
		hooksecurefunc("ChatEdit_InsertLink", insert)
	end
end

-- Dropping an item from the bags onto the editor links it too.
function Links.OnReceiveDrag(editBox)
	local kind, _, link = GetCursorInfo()
	if kind == "item" and link then
		editBox:Insert(link)
		ClearCursor()
	end
end
