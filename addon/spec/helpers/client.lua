-- A fake WoW client: just enough API to load addon/Corkboard/Corkboard.toc
-- with its real libraries, log in, run slash commands, and write
-- SavedVariables out and read them back the way a /reload does.
--
-- Each Client.new is a fresh client session with its own global table, so
-- nothing leaks from one "session" to the next except the saved text.
-- It models none of the client's timing or restrictions; it's for catching
-- load-order, wiring and persistence bugs.

local Client = {}
Client.__index = Client

local ADDON_DIR = "addon/Corkboard/"

-- The quests the fake game knows, by id: a client can load any of these
-- titles (C_QuestLog.RequestLoadQuestByID), and knows its own log's at once.
Client.QUEST_DB = {
	[7] = "Kobold Camp Cleanup",
	[15] = "Investigate Echo Ridge",
	[46] = "Bounty on Murlocs",
	[54] = "Report to Goldshire",
	[166] = "The Defias Brotherhood",
	[2040] = "Underground Assault",
}

local LUA_GLOBALS = {
	"assert", "collectgarbage", "error", "getfenv", "getmetatable", "ipairs", "loadstring", "next", "pairs",
	"pcall", "print", "rawequal", "rawget", "rawset", "select", "setfenv", "setmetatable", "tonumber",
	"tostring", "type", "unpack", "xpcall", "coroutine", "math", "string", "table",
}

-- Frames --------------------------------------------------------------------
-- Frames, font strings and textures share one permissive model. Methods it
-- doesn't know (capitalised names, like the client's API) are no-ops, so
-- layout calls just work. Lower-case fields read as nil, like on a real frame.

local Frame = {}
local function noop() end
Frame.__index = function(_, key)
	local method = Frame[key]
	if method ~= nil then
		return method
	end
	if type(key) == "string" and key:match("^%u") then
		return noop
	end
end

local function newRegion(kind, parent, name)
	return setmetatable({
		kind = kind,
		parent = parent,
		name = name,
		events = {},
		scripts = {},
		shown = true,
		enabled = true,
		text = "",
		width = 0,
	}, Frame)
end

function Frame:RegisterEvent(event)
	self.events[event] = true
end

function Frame:UnregisterEvent(event)
	self.events[event] = nil
end

function Frame:UnregisterAllEvents()
	self.events = {}
end

function Frame:IsEventRegistered(event)
	return self.events[event] or false
end

function Frame:SetScript(name, fn)
	self.scripts[name] = fn
end

function Frame:GetScript(name)
	return self.scripts[name]
end

function Frame:HookScript(name, fn)
	local old = self.scripts[name]
	self.scripts[name] = function(...)
		if old then
			old(...)
		end
		fn(...)
	end
end

function Frame:Run(script, ...)
	local fn = self.scripts[script]
	if fn then
		return fn(self, ...)
	end
end

function Frame:GetParent()
	return self.parent
end

function Frame:GetName()
	return self.name
end

function Frame:IsVisible()
	local frame = self
	while frame do
		if not frame.shown then
			return false
		end
		frame = frame.parent
	end
	return true
end

function Frame:Show()
	if not self.shown then
		self.shown = true
		self:Run("OnShow")
	end
end

function Frame:Hide()
	if self.shown then
		self.shown = false
		if self.hasFocus then
			self:ClearFocus()
		end
		self:Run("OnHide")
	end
end

function Frame:SetShown(shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end

function Frame:IsShown()
	return self.shown
end

function Frame.IsMouseOver()
	return false
end

function Frame:SetWidth(width)
	self.width = width
end

function Frame:SetSize(width)
	self.width = width
end

function Frame:GetWidth()
	return self.width
end

function Frame:GetHeight()
	return self.height or self.width
end

-- SetPoint keeps the last anchor, so tests can see where a button went.
function Frame:SetPoint(point, relativeTo, relativePoint, x, y)
	self.anchorPoint = { point, relativeTo, relativePoint, x, y }
end

-- Animation groups and their animations are plain regions (LibDBIcon's fade).
function Frame:CreateAnimationGroup()
	return newRegion("AnimationGroup", self)
end

function Frame:CreateAnimation(kind)
	return newRegion(kind, self)
end

function Frame:SetText(text)
	self.text = text or ""
	if self.kind == "EditBox" then
		self:Run("OnTextChanged", false)
	end
end

function Frame:GetText()
	return self.text
end

-- Roughly 6 units per byte and 14 per line, enough to size cards.
function Frame:GetStringHeight()
	if self.text == "" then
		return 0
	end
	local perLine = math.max(1, math.floor((self.width > 0 and self.width or 300) / 6))
	return 14 * math.ceil(#self.text / perLine)
end

function Frame:Insert(text)
	self.text = self.text .. text
	self:Run("OnTextChanged", true)
end

function Frame:SetFocus()
	self.hasFocus = true
end

function Frame:ClearFocus()
	self.hasFocus = false
end

function Frame:HasFocus()
	return self.hasFocus == true
end

function Frame:SetChecked(checked)
	self.checked = checked and true or false
end

function Frame:GetChecked()
	return self.checked == true
end

function Frame:SetEnabled(enabled)
	self.enabled = enabled and true or false
end

function Frame:Enable()
	self.enabled = true
end

function Frame:Disable()
	self.enabled = false
end

function Frame:IsEnabled()
	return self.enabled
end

-- A click as the player makes it: nothing happens on a disabled or hidden button.
function Frame:Click(button)
	assert(self:IsVisible(), "clicked a hidden button")
	assert(self.enabled, "clicked a disabled button")
	return self:Run("OnClick", button or "LeftButton")
end

-- Font strings are kept in frame.fontStrings so tests can read labels.
function Frame:CreateFontString(name)
	local region = newRegion("FontString", self, name)
	self.fontStrings = self.fontStrings or {}
	self.fontStrings[#self.fontStrings + 1] = region
	return region
end

function Frame:CreateTexture(name)
	return newRegion("Texture", self, name)
end

function Frame:SetTitle(title)
	self.title = title
end

-- WowScrollBoxList: builds a frame per element, like the client does for the
-- visible ones, and keeps them in box.elements for tests to inspect.
function Frame:SetDataProvider(provider)
	local view = assert(self.view, "SetDataProvider before InitScrollBoxListWithScrollBar")
	self.elements = self.elements or {}
	for _, element in ipairs(self.elements) do
		element:Hide()
	end
	for i, data in ipairs(provider.list) do
		local element = self.elements[i] or newRegion(view.template, self)
		self.elements[i] = element
		element.data = data
		element.extent = view.calculator and view.calculator(i, data) or view.extent
		view.initializer(element, data)
		element:Show()
	end
	self.count = #provider.list
end
-- Saved variables -------------------------------------------------------------

-- Writes a value as Lua source, the way the client writes SavedVariables.
local function serialize(value, indent)
	local t = type(value)
	if t == "string" then
		return string.format("%q", value)
	elseif t == "number" then
		if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			return string.format("%.0f", value)
		end
		return string.format("%.17g", value)
	elseif t == "boolean" then
		return tostring(value)
	elseif t == "table" then
		local keys = {}
		for k in pairs(value) do
			keys[#keys + 1] = k
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		local inner = indent .. "\t"
		local out = { "{\n" }
		for _, k in ipairs(keys) do
			out[#out + 1] = ("%s[%s] = %s,\n"):format(inner, serialize(k, inner), serialize(value[k], inner))
		end
		out[#out + 1] = indent .. "}"
		return table.concat(out)
	end
	error("can't save a " .. t)
end

-- The network --------------------------------------------------------------------
-- Shared by the clients in a test: password-protected temporary channels, a
-- guild, addon-message delivery with latency, and the server's per-sender,
-- per-prefix throttle (a token bucket, §11's burst 10 and 1 msg/s). Players
-- are keyed by "Name-Realm", so a /reload's fresh client takes over its
-- channels, as the server keeps them across a reload.

local Network = {}
Network.__index = Network
Client.Network = Network

Network.LATENCY = 0.1
Network.BURST = 10
Network.RATE = 1

function Network.new()
	return setmetatable({ players = {}, channels = {}, queue = {}, buckets = {}, delivered = {} }, Network)
end

function Network:attach(client)
	self.players[client:fullName()] = client
end

function Network:channel(name)
	return self.channels[name:lower()]
end

-- Queues fn to run `delay` seconds from now on the given client's clock.
function Network:later(client, delay, fn)
	self.queue[#self.queue + 1] = { client = client, at = client.time + delay, fn = fn }
end

function Network:deliverDue()
	local due = {}
	for i = #self.queue, 1, -1 do
		local item = self.queue[i]
		if item.at <= item.client.time then
			due[#due + 1] = table.remove(self.queue, i)
		end
	end
	for i = #due, 1, -1 do
		local item = due[i]
		-- Only to the player's current session.
		if self.players[item.client:fullName()] == item.client and item.client.loggedIn then
			item.fn()
		end
	end
end

function Network:take(client, prefix)
	local key = client:fullName() .. "\0" .. prefix
	local b = self.buckets[key] or { tokens = Network.BURST, at = client.time }
	self.buckets[key] = b
	b.tokens = math.min(Network.BURST, b.tokens + (client.time - b.at) * Network.RATE)
	b.at = client.time
	if b.tokens < 1 then
		return false
	end
	b.tokens = b.tokens - 1
	return true
end

-- Advances every client together, in small steps.
function Network:advance(seconds, clients)
	local step = 0.05
	local left = seconds
	while left > 1e-9 do
		local dt = math.min(step, left)
		for _, client in ipairs(clients) do
			client:step(dt)
		end
		self:deliverDue()
		left = left - dt
	end
	for _, client in ipairs(clients) do
		client:check()
	end
end

-- The client ------------------------------------------------------------------

-- options: saved (SavedVariables text from a previous session), name, realm,
-- guid, now (server time), network (shared with other clients), guild.
function Client.new(options)
	options = options or {}
	local self = setmetatable({
		frames = {},
		chat = {},
		errors = {},
		tickers = {},
		itemRefs = {},
		timers = {},
		loggedIn = false,
		now = options.now or 1790000000,
		time = options.time or 1000,
		saved = options.saved,
		cloud = options.cloud,
		name = options.name or "Will",
		realm = options.realm or "Mirage Raceway",
		guid = options.guid or "Player-4372-0ABCDEF0",
		class = options.class or "MAGE",
		guild = options.guild,
		network = options.network or Network.new(),
		prefixes = {},
		myChannels = {}, -- channel number -> name
		chatChannels = {}, -- channels ChatFrame1 shows, by lower-case name
		filters = {},
		secrets = {},
		locked = false,
		sentAddon = {},
		received = {},
		equipped = options.equipped or {}, -- slot -> { link, quality }
		-- The quest log, in order: { id, level } for a quest (its title comes
		-- from Client.QUEST_DB) or { header = "Zone" }.
		quests = options.quests or {},
		questCache = {}, -- quest id -> title, for quests loaded from QUEST_DB
		questRequests = {},
	}, Client)
	self.env = self:makeEnv()
	return self
end

function Client:fullName()
	return self.name .. "-" .. (self.realm:gsub("[%s%-]", ""))
end

-- Channel helpers -----------------------------------------------------------------------

function Client:channelNumber(name)
	for id, n in pairs(self.myChannels) do
		if n:lower() == name:lower() then
			return id
		end
	end
end

-- A chat event as the client handles it: message filters first, then the
-- default chat frame, which prints channel text and notices for channels it
-- shows (and every YOU_* notice about your own joins). Frames registered
-- for the event get it too.
function Client:chatEvent(event, ...)
	local suppressed = false
	for _, filter in ipairs(self.filters[event] or {}) do
		if filter(self.env.ChatFrame1, event, ...) then
			suppressed = true
		end
	end
	local channelName = select(9, ...)
	local notice = select(1, ...)
	if not suppressed then
		local shows = channelName and self.chatChannels[channelName:lower()]
		if shows or (event == "CHAT_MSG_CHANNEL_NOTICE" and type(notice) == "string" and notice:find("^YOU_")) then
			self.chat[#self.chat + 1] = ("[%s] %s"):format(tostring(select(4, ...)), tostring(notice))
		end
	end
	self.fire(event, ...)
end

function Client:joinChannel(name, password)
	local net = self.network
	local channel = net:channel(name)
	if channel and channel.password ~= (password or "") then
		net:later(self, Network.LATENCY, function()
			self:chatEvent("CHAT_MSG_CHANNEL_NOTICE_USER", "WRONG_PASSWORD", self:fullName(), "", "0. " .. name, "", "",
				0, 0, name)
		end)
		return
	end
	if not channel then
		channel = { name = name, password = password or "", members = {} }
		net.channels[name:lower()] = channel
	end
	net:later(self, Network.LATENCY, function()
		if self:channelNumber(name) then
			return
		end
		channel.members[self:fullName()] = true
		local id = 5
		while self.myChannels[id] do
			id = id + 1
		end
		self.myChannels[id] = name
		self.chatChannels[name:lower()] = true -- new channels show in the default chat frame
		self:chatEvent("CHAT_MSG_CHANNEL_NOTICE", "YOU_CHANGED", "", "", id .. ". " .. name, "", "", 0, id, name)
		self.fire("CHANNEL_UI_UPDATE")
	end)
end

function Client:leaveChannel(name)
	local id = self:channelNumber(name)
	if not id then
		return
	end
	self.myChannels[id] = nil
	self.chatChannels[name:lower()] = nil
	local channel = self.network:channel(name)
	if channel then
		channel.members[self:fullName()] = nil
		if next(channel.members) == nil then
			self.network.channels[name:lower()] = nil
		end
	end
	self:chatEvent("CHAT_MSG_CHANNEL_NOTICE", "YOU_LEFT", "", "", id .. ". " .. name, "", "", 0, id, name)
end

-- Delivers an addon message to one client, as CHAT_MSG_ADDON.
function Client:receiveAddon(prefix, text, chatType, sender, channelName)
	if not self.prefixes[prefix] then
		return
	end
	local senderName = sender:gsub("%-" .. (self.realm:gsub("[%s%-]", "")) .. "$", "") -- same realm: no suffix
	local localId = channelName and self:channelNumber(channelName) or 0
	self.received[#self.received + 1] = { prefix = prefix, text = text, chatType = chatType, sender = sender }
	self.fire("CHAT_MSG_ADDON", prefix, text, chatType, senderName, channelName or "", 0, localId, channelName or "", 0)
end

function Client:sendAddon(prefix, text, chatType, target)
	assert(type(prefix) == "string" and #prefix <= 16, "bad prefix")
	assert(type(text) == "string", "bad text")
	if #text > 255 then
		return 2 -- InvalidMessage
	end
	if self.locked then
		return 11 -- AddOnMessageLockdown
	end
	local net = self.network
	local recipients, channelName = {}, nil
	if chatType == "CHANNEL" then
		channelName = self.myChannels[tonumber(target)]
		if not channelName then
			return 7 -- InvalidChannel
		end
		for name in pairs(net:channel(channelName).members) do
			recipients[#recipients + 1] = name -- including ourselves: channel messages echo
		end
	elseif chatType == "GUILD" then
		if not self.guild then
			return 10 -- NotInGuild
		end
		for name, client in pairs(net.players) do
			if client.guild == self.guild then
				recipients[#recipients + 1] = name
			end
		end
	elseif chatType == "WHISPER" then
		recipients[1] = target
	else
		return 4 -- InvalidChatType
	end
	if not net:take(self, prefix) then
		return 3 -- AddonMessageThrottle
	end
	self.sentAddon[#self.sentAddon + 1] = { prefix = prefix, text = text, chatType = chatType, target = target }
	local from = self:fullName()
	for _, name in ipairs(recipients) do
		local client = net.players[name]
		if client then
			net:later(client, Network.LATENCY, function()
				client:receiveAddon(prefix, text, chatType, from, channelName)
			end)
		end
	end
	return 0
end

function Client:makeEnv()
	local client = self
	local env = {}
	for _, name in ipairs(LUA_GLOBALS) do
		env[name] = _G[name]
	end
	env._G = env
	-- WoW's xpcall passes extra arguments on to the function, like Lua 5.2's.
	env.xpcall = function(fn, handler, ...)
		local args, n = { ... }, select("#", ...)
		return xpcall(function()
			return fn(unpack(args, 1, n))
		end, handler)
	end

	local function fire(event, ...)
		for _, frame in ipairs(client.frames) do
			if frame.events[event] and frame.scripts.OnEvent then
				frame.scripts.OnEvent(frame, event, ...)
			end
		end
	end
	client.fire = fire

	env.CreateFrame = function(kind, name, parent, template)
		local frame = newRegion(kind, parent, name)
		frame.template = template
		if template == "ButtonFrameTemplate" then
			frame.Inset = newRegion("Frame", frame)
		end
		client.frames[#client.frames + 1] = frame
		if name then
			env[name] = frame
		end
		return frame
	end
	env.UIParent = newRegion("Frame")
	env.ChatFrame1 = newRegion("Frame", env.UIParent, "ChatFrame1")
	env.ChatFrame2 = newRegion("Frame", env.UIParent, "ChatFrame2")
	env.Minimap = newRegion("Frame", env.UIParent, "Minimap")
	env.Minimap.width = 140
	env.ReloadUI = function()
		client.reloadRequested = true
	end
	env.OKAY = "Okay"
	env.UISpecialFrames = {}
	env.ChatFontNormal = {}
	env.CANCEL, env.DELETE, env.SAVE = "Cancel", "Delete", "Save"

	-- ScrollBox lists (see Frame:SetDataProvider).
	env.CreateScrollBoxListLinearView = function()
		local view = {}
		function view.SetElementInitializer(_, template, initializer)
			view.template, view.initializer = template, initializer
		end
		function view.SetElementExtent(_, extent)
			view.extent = extent
		end
		function view.SetElementExtentCalculator(_, calculator)
			view.calculator = calculator
		end
		return view
	end
	env.ScrollUtil = {
		InitScrollBoxListWithScrollBar = function(box, _, view)
			box.view = view
		end,
	}
	env.ScrollBoxConstants = { RetainScrollPosition = 2 }
	env.CreateDataProvider = function(list)
		return { list = list or {} }
	end

	-- Links: the tooltip shows item, spell and quest links and raises an error
	-- for anything else, as the client does for types it can't show.
	env.GameTooltip = newRegion("GameTooltip")
	function env.GameTooltip.SetOwner(tooltip, owner)
		tooltip.owner = owner
	end
	function env.GameTooltip.SetHyperlink(tooltip, link)
		local kind = link:match("^(%a+):")
		assert(kind == "item" or kind == "spell" or kind == "quest", "Unknown link type")
		tooltip.link = link
	end
	env.SetItemRef = function(link, text, button)
		client.itemRefs[#client.itemRefs + 1] = { link = link, text = text, button = button }
	end
	env.ChatFrameUtil = {
		InsertLink = function()
			return false -- no chat edit box is open
		end,
	}
	env.GetCursorInfo = function()
		if client.cursor then
			return "item", 1, client.cursor
		end
	end
	env.ClearCursor = function()
		client.cursor = nil
	end

	-- StaticPopups: one dialog per popup name, shown with the formatted text.
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, a1, a2, data)
		local info = assert(env.StaticPopupDialogs[which], which)
		local dialog = newRegion("Frame", env.UIParent)
		dialog.which, dialog.data = which, data
		dialog.text = info.text:format(a1, a2)
		if info.hasEditBox then
			dialog.editBox = newRegion("EditBox", dialog)
		end
		function dialog.Hide(frame)
			frame.shown = false
			if client.popup == frame then
				client.popup = nil
			end
		end
		client.popup = dialog
		if info.OnShow then
			info.OnShow(dialog, data)
		end
		return dialog
	end
	env.hooksecurefunc = function(target, name, hook)
		if type(target) == "string" then
			target, name, hook = env, target, name
		end
		local original = target[name]
		target[name] = function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end
	end
	env.securecallfunction = function(fn, ...)
		return fn(...)
	end
	-- Libraries run addon callbacks under xpcall with this handler, so errors
	-- are collected here and Client:check() raises them.
	env.geterrorhandler = function()
		return function(err)
			client.errors[#client.errors + 1] = tostring(err)
		end
	end
	env.GetInventoryItemLink = function(unit, slot)
		local item = unit == "player" and client.equipped[slot]
		return item and item.link or nil
	end
	env.GetInventoryItemQuality = function(unit, slot)
		local item = unit == "player" and client.equipped[slot]
		return item and item.quality or nil
	end
	env.C_QuestLog = {
		GetNumQuestLogEntries = function()
			local quests = 0
			for _, entry in ipairs(client.quests) do
				quests = quests + (entry.header and 0 or 1)
			end
			return #client.quests, quests
		end,
		GetInfo = function(index)
			local entry = client.quests[index]
			if not entry then
				return nil
			elseif entry.header then
				return { title = entry.header, isHeader = true, isHidden = false, level = 0 }
			end
			return { title = Client.QUEST_DB[entry.id], questID = entry.id, level = entry.level, isHeader = false,
				isHidden = false }
		end,
		GetTitleForQuestID = function(id)
			for _, entry in ipairs(client.quests) do
				if entry.id == id then
					return Client.QUEST_DB[id]
				end
			end
			return client.questCache[id]
		end,
		-- Loads a quest's data a moment later, then fires QUEST_DATA_LOAD_RESULT.
		RequestLoadQuestByID = function(id)
			client.questRequests[#client.questRequests + 1] = id
			env.C_Timer.After(0.1, function()
				client.questCache[id] = Client.QUEST_DB[id]
				fire("QUEST_DATA_LOAD_RESULT", id, Client.QUEST_DB[id] ~= nil)
			end)
		end,
	}
	env.issecretvalue = function(value)
		return client.secrets[value] == true
	end
	env.IsLoggedIn = function()
		return client.loggedIn
	end
	env.GetTime = function()
		return client.time
	end
	env.GetFramerate = function()
		return 60
	end
	env.GetServerTime = function()
		return math.floor(client.now)
	end
	env.GetLocale = function()
		return "enUS"
	end
	env.GetCurrentRegion = function()
		return 3
	end
	env.GetCurrentRegionName = function()
		return "EU"
	end
	env.GetRealmName = function()
		return client.realm
	end
	env.GetNormalizedRealmName = function()
		return (client.realm:gsub("[%s%-]", ""))
	end
	-- Like Forever 1.60.1: a name can carry a surname ("Aprune Proudshield"),
	-- which UnitName and UnitFullName return where the realm usually goes.
	-- GetPlayerInfoByGUID has the whole name and an empty realm for our own.
	local first, surname = client.name:match("^(%S+)%s*(.*)$")
	surname = surname ~= "" and surname or nil
	env.UnitName = function()
		return first, surname
	end
	env.UnitFullName = function()
		return first, surname or env.GetNormalizedRealmName()
	end
	env.GetPlayerInfoByGUID = function(guid)
		if guid == client.guid then
			return "Mage", client.class, "Human", "Human", 2, client.name, ""
		end
	end
	env.UnitGUID = function()
		return client.guid
	end
	env.UnitClass = function()
		return "Mage", client.class, 8
	end
	env.UnitRace = function()
		return "Gnome", "Gnome", 7
	end
	env.UnitFactionGroup = function()
		return "Alliance", "Alliance"
	end
	env.Ambiguate = function(name)
		return name
	end
	env.Enum = { SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2,
		AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7,
		ChannelThrottle = 8, GeneralError = 9, NotInGuild = 10, AddOnMessageLockdown = 11 } }
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(prefix)
			client.prefixes[prefix] = true
			return 0
		end,
		IsAddonMessagePrefixRegistered = function(prefix)
			return client.prefixes[prefix] == true
		end,
		InChatMessagingLockdown = function()
			return client.locked, client.locked and 1 or 0
		end,
		SendAddonMessage = function(prefix, text, chatType, target)
			return client:sendAddon(prefix, text, chatType, target)
		end,
		SendAddonMessageLogged = function(prefix, text, chatType, target)
			return client:sendAddon(prefix, text, chatType, target)
		end,
	}
	env.IsInGuild = function()
		return client.guild ~= nil
	end
	env.JoinTemporaryChannel = function(name, password)
		client:joinChannel(name, password)
	end
	env.LeaveChannelByName = function(name)
		client:leaveChannel(name)
	end
	-- GetChannelName(name or number): number, name, 0; or 0 when not in it.
	env.GetChannelName = function(which)
		if type(which) == "number" then
			local name = client.myChannels[which]
			if name then
				return which, name, 0
			end
			return 0
		end
		local id = client:channelNumber(which)
		if id then
			return id, client.myChannels[id], 0
		end
		return 0
	end
	env.NUM_CHAT_WINDOWS = 2
	env.ChatFrame_RemoveChannel = function(frame, name)
		if frame == env.ChatFrame1 then
			client.chatChannels[name:lower()] = nil
		end
	end
	env.ChatFrame_AddMessageEventFilter = function(event, fn)
		client.filters[event] = client.filters[event] or {}
		table.insert(client.filters[event], fn)
	end
	env.C_Timer = {
		After = function(seconds, fn)
			client.timers[#client.timers + 1] = { at = client.time + seconds, fn = fn }
		end,
		NewTimer = function(seconds, fn)
			local timer = { at = client.time + seconds, fn = fn }
			function timer.Cancel()
				timer.cancelled = true
			end
			client.timers[#client.timers + 1] = timer
			return timer
		end,
		NewTicker = function(seconds, fn)
			local ticker = { seconds = seconds, fn = fn, at = client.time + seconds }
			function ticker.Cancel()
				ticker.cancelled = true
			end
			client.tickers[#client.tickers + 1] = ticker
			return ticker
		end,
	}
	env.SlashCmdList = {}
	env.hash_SlashCmdList = {}
	env.NORMAL_FONT_COLOR_CODE = "|cffffd100"
	env.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, text)
			client.chat[#client.chat + 1] = text
		end,
	}
	return env
end

function Client:loadLua(path)
	local chunk = assert(loadfile(path))
	setfenv(chunk, self.env)
	chunk("Corkboard", self.ns)
end

function Client:loadXml(path)
	local dir = path:match("^(.*/)") or ""
	local f = assert(io.open(path, "rb"))
	local xml = f:read("*a")
	f:close()
	for tag, file in xml:gmatch("<(%a+)%s+file=\"([^\"]+)\"") do
		local sub = dir .. file:gsub("\\", "/")
		if tag == "Script" then
			self:loadLua(sub)
		elseif tag == "Include" then
			self:loadXml(sub)
		end
	end
end

-- The files Corkboard.toc lists, in order, with "/" separators.
function Client.tocFiles()
	local files = {}
	for line in io.lines(ADDON_DIR .. "Corkboard.toc") do
		line = line:gsub("%s+$", "")
		if line ~= "" and not line:find("^#") then
			files[#files + 1] = (line:gsub("\\", "/"))
		end
	end
	return files
end

-- Loads the addon, then its SavedVariables, then logs in, like the client.
function Client:login()
	self.network:attach(self)
	self.ns = {}
	for _, file in ipairs(Client.tocFiles()) do
		if file:find("%.xml$") then
			self:loadXml(ADDON_DIR .. file)
		else
			self:loadLua(ADDON_DIR .. file)
		end
	end
	if self.saved then
		local chunk = assert(loadstring(self.saved, "SavedVariables/Corkboard.lua"))
		setfenv(chunk, self.env)
		chunk()
	end
	self.fire("ADDON_LOADED", "Corkboard")
	-- Corkboard_Cloud depends on Corkboard, so its Data.lua runs next,
	-- still before PLAYER_LOGIN.
	if self.cloud then
		local chunk = assert(loadstring(self.cloud, "Corkboard_Cloud/Data.lua"))
		setfenv(chunk, self.env)
		chunk()
		self.fire("ADDON_LOADED", "Corkboard_Cloud")
	end
	self.loggedIn = true
	self.fire("PLAYER_LOGIN")
	self.fire("PLAYER_ENTERING_WORLD", true, false)
	return self:check()
end

-- Raises any error a library caught and passed to the error handler.
function Client:check()
	if #self.errors > 0 then
		error("Lua errors in the client:\n" .. table.concat(self.errors, "\n"), 2)
	end
	return self
end

-- One small step of the clock: C_Timer callbacks and tickers that come due,
-- then every frame's OnUpdate.
function Client:step(dt)
	self.time = self.time + dt
	self.now = self.now + dt
	local due = {}
	for i = #self.timers, 1, -1 do
		if self.timers[i].at <= self.time then
			due[#due + 1] = table.remove(self.timers, i)
		end
	end
	for i = #due, 1, -1 do
		if not due[i].cancelled then
			due[i].fn()
		end
	end
	for _, ticker in ipairs(self.tickers) do
		if not ticker.cancelled and ticker.at <= self.time then
			ticker.at = ticker.at + ticker.seconds
			ticker.fn()
		end
	end
	for _, frame in ipairs(self.frames) do
		local onUpdate = frame.scripts.OnUpdate
		if onUpdate and frame:IsVisible() then
			onUpdate(frame, dt)
		end
	end
end

-- Advances the clock, running timers, tickers and OnUpdate as it goes, and
-- delivering this client's network traffic.
function Client:advance(seconds)
	self.network:advance(seconds, { self })
	return self
end

-- Runs "/cork ..." through the registered slash handler. Returns the chat
-- lines it printed, joined by "\n".
function Client:slash(text)
	local command, rest = text:match("^(/%S+)%s*(.*)$")
	local first = #self.chat + 1
	for key, value in pairs(self.env) do
		local id = type(key) == "string" and key:match("^SLASH_(.-)%d+$")
		if id and type(value) == "string" and value:lower() == command:lower() then
			self.env.SlashCmdList[id](rest, {})
			self:check()
			return table.concat(self.chat, "\n", first)
		end
	end
	error("no slash command " .. command)
end

-- Store shortcuts, standing in for what the board window does: each change
-- goes through the addon's store, then the window redraws.
function Client:store()
	return self.ns.Corkboard.store
end

function Client:board()
	return self:store():current()
end

local function changed(self, ...)
	self.ns.Corkboard:Changed()
	self:check()
	return ...
end

function Client:createBoard(name)
	return changed(self, assert(self:store():createBoard(name)))
end

function Client:addNote(text)
	return changed(self, assert(self:store():addNote(self:board().id, text)))
end

-- The i-th live note on the current board, oldest first.
function Client:note(i)
	return self.ns.Store.notes(self:board())[i]
end

function Client:editNote(i, changes)
	return changed(self, assert(self:store():editNote(self:board().id, self:note(i).id, changes)))
end

function Client:deleteNote(i)
	return changed(self, assert(self:store():deleteNote(self:board().id, self:note(i).id)))
end

-- The current board's live note texts, oldest first, joined by "\n".
function Client:noteTexts()
	local texts = {}
	for _, note in ipairs(self.ns.Store.notes(self:board())) do
		texts[#texts + 1] = note.text
	end
	return table.concat(texts, "\n"), #texts
end

-- Logs out and returns the SavedVariables text the client would write.
function Client:logout()
	self.fire("PLAYER_LOGOUT")
	self:check()
	local db = self.env.CorkboardDB
	if db == nil then
		return nil
	end
	return "CorkboardDB = " .. serialize(db, "") .. "\n"
end

-- A /reload: log out, then log in again as a fresh session from the saved text.
function Client:reload()
	local saved = self:logout()
	local fresh = Client.new({
		saved = saved,
		now = self.now,
		time = self.time,
		name = self.name,
		realm = self.realm,
		guid = self.guid,
		class = self.class,
		guild = self.guild,
		network = self.network,
		equipped = self.equipped,
		quests = self.quests,
	})
	-- The server keeps channel membership across a /reload.
	fresh.myChannels = self.myChannels
	return fresh:login()
end

-- The popup on screen: its accept button, or typing and pressing Enter.
function Client:acceptPopup()
	local dialog = assert(self.popup, "no popup is showing")
	local info = self.env.StaticPopupDialogs[dialog.which]
	if not info.OnAccept(dialog, dialog.data) then
		dialog:Hide()
	end
	return self:check()
end

function Client:typeInPopup(text)
	local dialog = assert(self.popup, "no popup is showing")
	local info = self.env.StaticPopupDialogs[dialog.which]
	dialog.editBox:SetText(text)
	info.EditBoxOnEnterPressed(dialog.editBox, dialog.data)
	return self:check()
end

-- A shift-click on a link somewhere in the game's UI.
-- Puts an item in an equipment slot (nil empties it), as the paper doll does.
function Client:equip(slot, link, quality)
	self.equipped[slot] = link and { link = link, quality = quality } or nil
	self.fire("PLAYER_EQUIPMENT_CHANGED", slot, link == nil)
	return self:check()
end

-- Replaces the quest log (see Client.new) and fires QUEST_LOG_UPDATE, as
-- accepting, abandoning or turning in a quest does. Pass nil to fire the
-- event without a change, as killing a mob for an objective does.
function Client:setQuests(quests)
	self.quests = quests or self.quests
	self.fire("QUEST_LOG_UPDATE")
	return self:check()
end

function Client:shiftClick(link)
	self.env.ChatFrameUtil.InsertLink(link)
	return self:check()
end

return Client
