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

-- The client ------------------------------------------------------------------

-- options: saved (SavedVariables text from a previous session), name, realm,
-- guid, now (server time).
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
		time = 1000,
		saved = options.saved,
		name = options.name or "Will",
		realm = options.realm or "Mirage Raceway",
		guid = options.guid or "Player-4372-0ABCDEF0",
	}, Client)
	self.env = self:makeEnv()
	return self
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
	env.issecretvalue = function()
		return false
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
		return client.now
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
	env.UnitName = function()
		return client.name
	end
	env.UnitFullName = function()
		return client.name, env.GetNormalizedRealmName()
	end
	env.UnitGUID = function()
		return client.guid
	end
	env.UnitClass = function()
		return "Mage", "MAGE", 8
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
	env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, AddOnMessageLockdown = 11 } }
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function()
			return 0
		end,
		IsAddonMessagePrefixRegistered = function()
			return false
		end,
		InChatMessagingLockdown = function()
			return false
		end,
		SendAddonMessage = function()
			error("Corkboard doesn't send addon messages in Phase 1")
		end,
		SendAddonMessageLogged = function()
			error("Corkboard doesn't send addon messages in Phase 1")
		end,
	}
	env.C_Timer = {
		After = function(seconds, fn)
			client.timers[#client.timers + 1] = { at = client.time + seconds, fn = fn }
		end,
		NewTicker = function(seconds, fn)
			local ticker = { seconds = seconds, fn = fn }
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

-- Advances the clock, running any C_Timer callbacks that come due.
function Client:advance(seconds)
	self.time = self.time + seconds
	self.now = self.now + seconds
	local due = {}
	for i = #self.timers, 1, -1 do
		if self.timers[i].at <= self.time then
			due[#due + 1] = table.remove(self.timers, i)
		end
	end
	for i = #due, 1, -1 do
		due[i].fn()
	end
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
	return Client.new({
		saved = saved,
		now = self.now,
		name = self.name,
		realm = self.realm,
		guid = self.guid,
	}):login()
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
function Client:shiftClick(link)
	self.env.ChatFrameUtil.InsertLink(link)
	return self:check()
end

return Client
