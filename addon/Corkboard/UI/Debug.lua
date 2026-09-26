-- The /cork debug panel (docs/design.md §11, docs/mockups/Debug.dc.html):
-- send gate, outbox and throttle stats; the 32 buckets against a peer; the
-- peers table; and the sync log.

local _, ns = ...
local View, Store, Digest = ns.View, ns.Store, ns.Digest

local Debug = {}
ns.Debug = Debug

local WIDTH, HEIGHT = 700, 470
local PAD = 12
local STATS = 8
local PEERS = 8
local LOG = 12
local CELL = 22
local BUCKET_BAD = { 0x4a / 255, 0x3a / 255, 0x1c / 255 }
local BUCKET_OK = { 0x1e / 255, 0x1c / 255, 0x19 / 255 }
local DIM = { 0x6f / 255, 0x6a / 255, 0x60 / 255 }
local GOLD = { 1, 0.82, 0 }

local frame, ui

local function addon()
	return ns.Corkboard
end

local function lines(parent, count, font, anchor, x, y, width, spacing)
	local out = {}
	for i = 1, count do
		local fs = parent:CreateFontString(nil, "OVERLAY", font)
		fs:SetPoint("TOPLEFT", anchor, "TOPLEFT", x, y - (i - 1) * spacing)
		fs:SetWidth(width)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(false)
		out[i] = fs
	end
	return out
end

local function build()
	frame = CreateFrame("Frame", "CorkboardDebug", UIParent, "ButtonFrameTemplate")
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
	frame:SetPoint("CENTER", 120, -40)
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	if frame.SetTitle then
		frame:SetTitle("Corkboard Debug")
	end
	table.insert(UISpecialFrames, "CorkboardDebug")
	frame:Hide()
	ui = {}

	ui.board = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ui.board:SetPoint("TOPLEFT", PAD, -32)
	ui.hello = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	ui.hello:SetSize(100, 22)
	ui.hello:SetText("Force HELLO")
	ui.hello:SetPoint("TOPRIGHT", -PAD, -28)
	ui.hello:SetScript("OnClick", function()
		local board = addon().store:current()
		if board then
			addon().sync:hello(board.id)
		end
	end)

	-- Stats, left.
	local stats = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	stats:SetPoint("TOPLEFT", PAD, -58)
	stats:SetSize(300, 150)
	ui.keys = lines(stats, STATS, "GameFontDisableSmall", stats, 8, -8, 100, 17)
	ui.values = lines(stats, STATS, "GameFontHighlightSmall", stats, 110, -8, 184, 17)

	-- Buckets, right.
	local grid = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	grid:SetPoint("TOPLEFT", stats, "TOPRIGHT", 8, 0)
	grid:SetPoint("BOTTOMRIGHT", stats, "BOTTOMRIGHT", WIDTH - 2 * PAD - 300, 0)
	ui.gridLabel = grid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	ui.gridLabel:SetPoint("TOPLEFT", 8, -8)
	ui.cells = {}
	for i = 0, Digest.BUCKETS - 1 do
		local cell = CreateFrame("Frame", nil, grid)
		cell:SetSize(CELL + 20, CELL)
		cell:SetPoint("TOPLEFT", 8 + (i % 8) * (CELL + 22), -28 - math.floor(i / 8) * (CELL + 6))
		cell.bg = cell:CreateTexture(nil, "BACKGROUND")
		cell.bg:SetAllPoints()
		cell.text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		cell.text:SetPoint("CENTER")
		cell.text:SetText(("%02d"):format(i))
		ui.cells[i] = cell
	end

	-- Peers.
	local peers = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	peers:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -8)
	peers:SetPoint("RIGHT", -PAD, 0)
	peers:SetHeight(24 + PEERS * 15)
	local columns = { { "Member", 8, 150 }, { "Last HELLO", 160, 90 }, { "Digest", 250, 200 }, { "State", 460, 150 } }
	ui.peerCols = {}
	for c, col in ipairs(columns) do
		local head = peers:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		head:SetPoint("TOPLEFT", col[2], -6)
		head:SetText(col[1])
		ui.peerCols[c] = lines(peers, PEERS, "GameFontHighlightSmall", peers, col[2], -22, col[3], 15)
	end

	-- Log.
	local log = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	log:SetPoint("TOPLEFT", peers, "BOTTOMLEFT", 0, -8)
	log:SetPoint("BOTTOMRIGHT", -PAD, PAD)
	ui.log = lines(log, LOG, "GameFontHighlightSmall", log, 8, -6, WIDTH - 2 * PAD - 16, 13)

	frame:SetScript("OnShow", function()
		Debug:Refresh()
		ui.ticker = C_Timer.NewTicker(1, function()
			Debug:Refresh()
		end)
	end)
	frame:SetScript("OnHide", function()
		if ui.ticker then
			ui.ticker:Cancel()
			ui.ticker = nil
		end
	end)
end

-- The peer whose buckets to compare against: the most recent HELLO.
local function latestPeer(peers)
	local best
	for _, peer in pairs(peers or {}) do
		if peer.buckets and (not best or peer.hello > best.hello) then
			best = peer
		end
	end
	return best
end

function Debug:Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	local cb = addon()
	local store, sync = cb.store, cb.sync
	local board = store:current()
	local now = cb.syncEnv.time()
	ui.board:SetText(board and Store.name(board) or "No board selected")
	ui.hello:SetEnabled(board ~= nil)

	for i, row in ipairs(View.debugStats(cb.outbox, cb.gate.name, board, now)) do
		ui.keys[i]:SetText(row[1])
		ui.values[i]:SetText(row[2])
	end

	local mine = board and sync:summary(board)
	local peers = board and sync.peers[board.id]
	local peer = latestPeer(peers)
	local bad = {}
	if mine and peer then
		for _, b in ipairs(Digest.mismatched(mine.buckets, peer.buckets)) do
			bad[b] = true
		end
		local n = 0
		for _ in pairs(bad) do
			n = n + 1
		end
		local name = View.shortName(peer.name, View.realmOf(store.env.me))
		ui.gridLabel:SetText(("Buckets vs %s: %d of 32 differ"):format(name, n))
	else
		ui.gridLabel:SetText("Buckets: no HELLO from a member yet")
	end
	for i = 0, Digest.BUCKETS - 1 do
		local cell = ui.cells[i]
		cell.bg:SetColorTexture(unpack(bad[i] and BUCKET_BAD or BUCKET_OK))
		cell.text:SetTextColor(unpack(bad[i] and GOLD or DIM))
	end

	local rows = {}
	if board then
		rows[1] = { "You", "-", View.digestLabel(mine.count, board.clock, mine.digest), "self" }
		for name, p in pairs(peers or {}) do
			rows[#rows + 1] = {
				View.shortName(name, View.realmOf(store.env.me)),
				p.hello and View.shortAge(now - p.hello) or "-",
				p.digest and View.digestLabel(p.count, p.clock, p.digest) or "-",
				sync:online(p) and (p.state or "heard") or "offline",
			}
		end
	end
	for r = 1, PEERS do
		for c = 1, 4 do
			ui.peerCols[c][r]:SetText(rows[r] and rows[r][c] or "")
		end
	end

	local log = sync.log
	for i = 1, LOG do
		local entry = log[#log - LOG + i]
		ui.log[i]:SetText(entry and (date and date("%H:%M:%S", entry.t) or tostring(entry.t)) .. "  " .. entry.line or "")
	end
end

function Debug:Toggle()
	if not frame then
		build()
	end
	frame:SetShown(not frame:IsShown())
end
