-- The transport (docs/design.md §5.1, §5.2): the WoW side of the outbox.
-- It keeps each board's hidden, password-protected channel joined and out of
-- every chat frame, hands messages to ChatThrottleLib in chunks, and turns
-- CHAT_MSG_ADDON back into envelopes for the sync engine.
--
-- This is the one place that sends addon messages. Feature code queues
-- through the outbox (§5.5, §5.6).

local _, ns = ...
local Store, Wire = ns.Store, ns.Wire

local Net = {}
ns.Net = Net

Net.MAX_CHANNELS = 3 -- channel-backed boards per character (§5.1)
Net.JOIN_DELAY = 8 -- seconds after logging in before joining, so the game's own channels keep 1-4
Net.RETRY_JOIN = 30 -- seconds before trying a channel again after a failed join

local addon -- the Corkboard addon object
local frame
local reassembler
local channels = {} -- channel name (lower case) -> board id, for channels we mean to be in
local byBoard = {} -- board id -> channel name
local tried = {} -- channel name -> GetTime() of the last join attempt
local started = false

Net.stats = { secret = 0, received = 0, ignored = 0, undecodable = 0, sent = 0 }

local function store()
	return addon.store
end

local function lower(s)
	return type(s) == "string" and s:lower() or nil
end

local function secret(...)
	if not issecretvalue then
		return false
	end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then
			return true
		end
	end
	return false
end

-- Chat frames ----------------------------------------------------------------------

-- Takes a channel out of every chat frame, with whichever function this
-- client has (spike 03 confirms which).
local function hide(name)
	for i = 1, NUM_CHAT_WINDOWS or 10 do
		local chatFrame = _G["ChatFrame" .. i]
		if chatFrame then
			if ChatFrame_RemoveChannel then
				pcall(ChatFrame_RemoveChannel, chatFrame, name)
			elseif ChatFrameUtil and ChatFrameUtil.RemoveChannel then
				pcall(ChatFrameUtil.RemoveChannel, chatFrame, name)
			elseif chatFrame.RemoveChannel then
				pcall(chatFrame.RemoveChannel, chatFrame, name)
			end
		end
	end
end

-- Whether a chat event is about one of our channels. Chat events carry the
-- channel's base name in arg 9 and "N. Name" in arg 4.
local function ours(channelString, channelName)
	if channelName and channels[lower(channelName)] then
		return true
	end
	local base = type(channelString) == "string" and channelString:match("^%d+%.%s*(.+)$")
	return base ~= nil and channels[lower(base)] ~= nil
end

-- A message filter (not a hook): the join and leave notices and any text on
-- our channels never reach a chat frame.
local function filter(_, _, ...)
	local channelString, channelName = select(4, ...), select(9, ...)
	if secret(channelString, channelName) then
		return false
	end
	return ours(channelString, channelName)
end

local function addFilter(event)
	local add = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
	if add then
		add(event, filter)
	end
end

-- Channels ---------------------------------------------------------------------------

-- The channel number we're in for a name, or nil.
local function channelId(name)
	local id = GetChannelName(name)
	if type(id) == "number" and id > 0 then
		return id
	end
end

-- Boards that get a channel: not guild boards, the current board first, then
-- the most recently used, up to MAX_CHANNELS.
function Net.wanted(boards, current)
	local list = {}
	for _, board in ipairs(boards) do
		if not board.guild and not (board.sync and board.sync.expired) then
			list[#list + 1] = board
		end
	end
	table.sort(list, function(a, b)
		if (a == current) ~= (b == current) then
			return a == current
		end
		local ua, ub = a.sync and a.sync.lastUsed or 0, b.sync and b.sync.lastUsed or 0
		if ua ~= ub then
			return ua > ub
		end
		return a.id < b.id
	end)
	local out = {}
	for i = 1, math.min(#list, Net.MAX_CHANNELS) do
		out[i] = list[i]
	end
	return out
end

-- Joins the channels the boards need and leaves the ones they don't.
function Net:Refresh()
	if not started then
		return
	end
	local want = {}
	for _, board in ipairs(Net.wanted(store():boards(), store():current())) do
		want[board.id] = Store.channelName(board)
	end
	-- Leave channels for boards that no longer want one (deleted, rotated,
	-- guild, or pushed out by the cap).
	for id, name in pairs(byBoard) do
		if want[id] ~= name then
			if channelId(name) then
				LeaveChannelByName(name)
			end
			channels[lower(name)] = nil
			byBoard[id] = nil
		end
	end
	local now = GetTime()
	for id, name in pairs(want) do
		byBoard[id] = name
		channels[lower(name)] = id
		if channelId(name) then
			hide(name)
		elseif not tried[name] or now - tried[name] >= Net.RETRY_JOIN then
			tried[name] = now
			JoinTemporaryChannel(name, store():board(id).secret)
			hide(name)
		end
	end
end

-- The channel state of a board, for the UI: "joined", "joining", "guild",
-- "expired" (wrong password: the invite is out of date) or "limit" (more
-- boards than channels).
function Net:ChannelState(board)
	if board.guild then
		return "guild"
	elseif board.sync and board.sync.expired then
		return "expired"
	end
	local name = byBoard[board.id]
	if not name then
		return "limit"
	end
	return channelId(name) and "joined" or "joining"
end

-- Sending ------------------------------------------------------------------------------

-- Where a board's messages go: chat type and target, or nil while unreachable.
local function route(boardId)
	local board = store():board(boardId)
	if not board then
		return nil
	end
	if board.guild then
		if IsInGuild() then
			return "GUILD", nil
		end
		return nil
	end
	local name = byBoard[boardId]
	local id = name and channelId(name)
	if id then
		return "CHANNEL", tostring(id)
	end
end

function Net:Ready(dest)
	return route(dest.board) ~= nil
end

-- Sends one encoded message as chunks through ChatThrottleLib, and calls
-- done(outcome) once: "lockdown" if any chunk was refused as
-- restricted, "error" for any other failure, otherwise "ok".
function Net:Send(dest, text, prio, done)
	local chatType, target = route(dest.board)
	if not chatType then
		return done("wait")
	end
	local chunks = Wire.split(text)
	if not chunks then
		return done("error") -- too long
	end
	local left, worst = #chunks, "ok"
	local function result(_, didSend, sendResult)
		local outcome = addon.gate:classify(sendResult)
		if outcome == "throttle" then
			return -- ChatThrottleLib re-queues these itself
		end
		if (outcome ~= "ok" or not didSend) and worst ~= "lockdown" then
			worst = outcome == "lockdown" and "lockdown" or "error"
		end
		left = left - 1
		if left == 0 then
			Net.stats.sent = Net.stats.sent + #chunks
			done(worst)
		end
	end
	local CTL = ChatThrottleLib
	for _, chunk in ipairs(chunks) do
		CTL:SendAddonMessage(prio, Wire.PREFIX, chunk, chatType, target, "CORK" .. dest.board, result)
	end
end

-- Receiving -----------------------------------------------------------------------------

local function fullName(sender)
	if sender:find("-", 1, true) then
		return sender
	end
	return sender .. "-" .. (GetNormalizedRealmName() or "")
end

-- A "Name-Realm" compared without case or the realm's spaces, hyphens and
-- apostrophes: CorkSpike on 1.60.1 failed to recognise its own whispers by
-- exact name, so the realm's spelling in `sender` isn't trusted to match ours.
local function nameKey(name)
	local base, realm = name:match("^([^-]+)%-(.*)$")
	if not base then
		return name:lower()
	end
	return base:lower() .. "-" .. (realm:gsub("[%s%-']", "")):lower()
end

local warnedEcho
local function isSelf(sender)
	local me = addon:Identify()
	if not me then
		return false
	end
	if nameKey(sender) == nameKey(me) then
		return true
	end
	if not warnedEcho and nameKey(sender):match("^[^-]+") == nameKey(me):match("^[^-]+") then
		warnedEcho = true -- same name, other realm: a namesake, or an echo we can't recognise
		addon.sync:note("? %s shares our name (we are %s)", sender, me)
	end
	return false
end

-- The board a CHANNEL message belongs to, from the event's channel details.
local function channelBoard(target, localId, channelName)
	for _, name in ipairs({ channelName, target }) do
		if type(name) == "string" and channels[lower(name)] then
			return channels[lower(name)]
		end
	end
	if type(localId) == "number" then
		local _, name = GetChannelName(localId)
		return name and channels[lower(name)]
	end
end

function Net:OnAddonMessage(prefix, text, chatType, sender, target, _, localId, channelName)
	-- Secret values first: nothing else may touch them (§2).
	if secret(prefix, text, chatType, sender, target, channelName) then
		Net.stats.secret = Net.stats.secret + 1
		return
	end
	if prefix ~= Wire.PREFIX then
		return
	end
	Net.stats.received = Net.stats.received + 1
	local boardId
	if chatType == "CHANNEL" then
		boardId = channelBoard(target, localId, channelName)
	elseif chatType == "GUILD" then
		boardId = "GUILD"
	end
	if not boardId or type(sender) ~= "string" then
		Net.stats.ignored = Net.stats.ignored + 1
		return
	end
	sender = fullName(sender)
	if isSelf(sender) then
		return -- our own broadcast, echoed back
	end
	local whole = reassembler:add(sender .. "\0" .. chatType .. "\0" .. boardId, text, GetTime())
	if not whole then
		return
	end
	local envelope = addon.wire:decode(whole)
	if not envelope then
		Net.stats.undecodable = Net.stats.undecodable + 1
		return
	end
	-- A board's traffic only counts on its own channel, or on GUILD for a guild board.
	local board = store():board(envelope.b)
	if not board or (boardId == "GUILD" and not board.guild) or (boardId ~= "GUILD" and boardId ~= envelope.b) then
		Net.stats.ignored = Net.stats.ignored + 1
		return
	end
	addon.sync:receive(envelope, sender)
	addon.outbox:pump()
end

-- A wrong password means the board's secret has been rotated without us:
-- the invite we joined with is out of date.
function Net:OnChannelNotice(notice, _, _, channelString, _, _, _, _, channelName)
	if secret(notice, channelString, channelName) or notice ~= "WRONG_PASSWORD" then
		return
	end
	local base = channelName or (type(channelString) == "string" and channelString:match("^%d+%.%s*(.+)$"))
	local id = base and channels[lower(base)]
	local board = id and store():board(id)
	if board then
		board.sync = board.sync or {}
		board.sync.expired = true
		addon:Expired(board)
		Net:Refresh()
	end
end

-- Setup ------------------------------------------------------------------------------------

function Net:Init(corkboard)
	addon = corkboard
	reassembler = Wire.Reassembler.new()
	C_ChatInfo.RegisterAddonMessagePrefix(Wire.PREFIX)
	for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL",
		"CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
		addFilter(event)
	end
	frame = CreateFrame("Frame")
	frame:RegisterEvent("CHAT_MSG_ADDON")
	frame:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER")
	frame:RegisterEvent("CHANNEL_UI_UPDATE")
	frame:SetScript("OnEvent", function(_, event, ...)
		if event == "CHAT_MSG_ADDON" then
			Net:OnAddonMessage(...)
		elseif event == "CHAT_MSG_CHANNEL_NOTICE_USER" then
			Net:OnChannelNotice(...)
		elseif event == "CHANNEL_UI_UPDATE" then
			for _, name in pairs(byBoard) do
				hide(name)
			end
		end
	end)
end

-- Joins the board channels. Called a few seconds after logging in.
function Net:Start()
	started = true
	self:Refresh()
end
