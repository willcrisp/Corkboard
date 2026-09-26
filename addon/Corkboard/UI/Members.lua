-- The Members tab (docs/ui-style.md "Members tab", docs/mockups/Share.dc.html):
-- the invite string to copy, Rotate Secret, the cloud and guild options, and
-- the roster. It sits in the main window's note area while its tab is chosen.

local _, ns = ...
local button = ns.Main.Button
local View, Store, Invite = ns.View, ns.Store, ns.Invite

local Members = {}
ns.Members = Members

local ROW = 22
local PAD = 10
local COLUMNS = { { "Name", 0 }, { "Role", 170 }, { "Last Seen", 250 }, { "Sync", 340 } }
local DIM = { 0x9d / 255, 0x9d / 255, 0x9d / 255 }
local TEXT = { 0.9, 0.9, 0.9 }

local panel, ui
local boardId

local function addon()
	return ns.Corkboard
end

local function store()
	return addon().store
end

local function classColor(class)
	if not class then
		return nil
	end
	local color = C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class)
	if not color and RAID_CLASS_COLORS then
		color = RAID_CLASS_COLORS[class]
	end
	return color and { color.r, color.g, color.b } or nil
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

local function initRow(row, data)
	if not row.cells then
		row.cells = {}
		for i, column in ipairs(COLUMNS) do
			local cell = row:CreateFontString(nil, "OVERLAY", i == 1 and "GameFontHighlight" or "GameFontHighlightSmall")
			cell:SetPoint("LEFT", column[2] + 4, 0)
			cell:SetWidth((COLUMNS[i + 1] and COLUMNS[i + 1][2] or 440) - column[2] - 8)
			cell:SetJustifyH("LEFT")
			cell:SetWordWrap(false)
			row.cells[i] = cell
		end
		row.shade = row:CreateTexture(nil, "BACKGROUND")
		row.shade:SetAllPoints()
		row.shade:SetColorTexture(1, 1, 1, 0.03)
		row.remove = CreateFrame("Button", nil, row)
		row.remove:SetSize(16, 16)
		row.remove:SetPoint("RIGHT", -4, 0)
		row.remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
		row.remove:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		row.remove:SetScript("OnClick", function(self)
			ns.Popups.RemoveMember(boardId, self:GetParent().member)
		end)
		row.remove:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Remove " .. (self:GetParent().label or ""))
			GameTooltip:Show()
		end)
		row.remove:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end
	row.member, row.label = data.name, data.label
	row.shade:SetShown(data.index % 2 == 0)
	local values = { data.label, data.role, data.seen, data.sync }
	for i, cell in ipairs(row.cells) do
		cell:SetText(values[i])
		cell:SetTextColor(unpack(data.online and TEXT or DIM))
	end
	local color = data.online and classColor(data.class)
	if color then
		row.cells[1]:SetTextColor(unpack(color))
	end
	row.remove:SetShown(data.removable)
end

function Members.Build(_, inset)
	panel = CreateFrame("Frame", nil, inset)
	panel:SetAllPoints()
	panel:Hide()
	ui = {}

	local invite = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	invite:SetPoint("TOPLEFT", PAD, -PAD)
	invite:SetText("Invite")
	ui.owner = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.owner:SetPoint("TOPRIGHT", -PAD, -PAD - 2)

	ui.rotate = button(panel, "Rotate Secret", 110)
	ui.rotate:SetPoint("TOPRIGHT", -PAD, -PAD - 18)
	ui.rotate:SetScript("OnClick", function()
		ns.Popups.RotateSecret(boardId)
	end)
	ui.invite = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	ui.invite:SetHeight(20)
	ui.invite:SetPoint("TOPLEFT", PAD + 6, -PAD - 19)
	ui.invite:SetPoint("RIGHT", ui.rotate, "LEFT", -10, 0)
	ui.invite:SetAutoFocus(false)
	ui.invite:SetFontObject(ChatFontNormal)
	-- Read-only: typing puts the invite back; focusing selects it for Ctrl+C.
	ui.invite:SetScript("OnTextChanged", function(box, user)
		if user and ui.text then
			box:SetText(ui.text)
			box:HighlightText()
		end
	end)
	ui.invite:SetScript("OnEditFocusGained", function(box)
		box:HighlightText()
	end)
	ui.invite:SetScript("OnEscapePressed", function(box)
		box:ClearFocus()
	end)
	local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", ui.invite, "BOTTOMLEFT", -6, -4)
	hint:SetText("Click it and press Ctrl+C to copy. Anyone with this string can read and edit the board.")

	ui.cloud = checkbox(panel, "Cloud sync", function(checked)
		store():setOption(boardId, "cloud", checked)
		addon():Changed()
	end)
	ui.cloud:SetPoint("TOPLEFT", PAD - 4, -PAD - 62)
	ui.guild = checkbox(panel, "Also sync over guild chat", function(checked)
		store():setOption(boardId, "guild", checked)
		addon():Changed()
	end)
	ui.guild:SetPoint("LEFT", ui.cloud.label, "RIGHT", 24, 0)

	local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("TOPLEFT", PAD, -PAD - 98)
	heading:SetText("Members")
	ui.headers = {}
	for i, column in ipairs(COLUMNS) do
		local h = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		h:SetPoint("TOPLEFT", PAD + column[2] + 4, -PAD - 118)
		h:SetText(column[1])
		ui.headers[i] = h
	end

	ui.list = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	ui.list:SetPoint("TOPLEFT", PAD, -PAD - 132)
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

function Members:Refresh(board)
	if not panel or not panel:IsShown() then
		return
	end
	boardId = board and board.id
	if not board then
		return
	end
	local s = store()
	local me = s.env.me
	ui.text = Invite.encode(board)
	ui.invite:SetText(ui.text)
	ui.invite:SetCursorPosition(0)
	local owner = s:isOwner(board)
	ui.owner:SetText(owner and "You're the owner" or ("Owner: " .. View.shortName(board.owner, View.realmOf(me))))
	ui.rotate:SetShown(owner)
	ui.cloud:SetChecked(board.cloud)
	ui.guild:SetChecked(board.guild)
	local sync = addon().sync
	local rows = View.memberRows(board, Store.members(board), sync.peers[board.id], sync:onlineNames(board.id), me,
		s.env.now(), View.realmOf(me))
	for i, row in ipairs(rows) do
		row.index = i
	end
	ui.list:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
end

-- For tests: the invite box and the roster.
function Members.Widgets()
	return ui
end
