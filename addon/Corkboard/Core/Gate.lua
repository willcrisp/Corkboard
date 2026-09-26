-- The lockdown gate and send results (docs/design.md §5.5). Pure Lua 5.1: the
-- client's globals come in through `get(name)`, so busted can play any client.
--
-- Spike 01 hasn't named the client's outgoing addon-message restriction check
-- on 16001 yet, so the gate uses the first of Gate.CHECKS that exists.
-- Whichever it finds, a send whose result code means "restricted" also
-- closes the gate (Outbox:result).

local _, ns = ...
ns = type(ns) == "table" and ns or {}

local find, lower = string.find, string.lower

local Gate = {}
Gate.__index = Gate

-- { namespace, function }, in order of preference. A nil namespace means a
-- global function. Each returns true (plus anything) while sends are
-- restricted.
Gate.CHECKS = {
	{ "C_ChatInfo", "InChatMessagingLockdown" },
	{ "C_ChatInfo", "AreOutgoingAddonChatMessagesRestricted" },
	{ nil, "AreOutgoingAddonChatMessagesRestricted" },
}

-- Finds the restriction check. Returns the function and its name, or nil.
function Gate.resolve(get)
	for _, check in ipairs(Gate.CHECKS) do
		local space, name = check[1], check[2]
		local fn
		if space then
			local t = get(space)
			fn = type(t) == "table" and t[name] or nil
		else
			fn = get(name)
		end
		if type(fn) == "function" then
			return fn, (space and space .. "." or "") .. name
		end
	end
	return nil
end

function Gate.new(get)
	local fn, name = Gate.resolve(get)
	local results = get("Enum")
	results = type(results) == "table" and results.SendAddonMessageResult or nil
	local names = {}
	if type(results) == "table" then
		for key, value in pairs(results) do
			names[value] = key
		end
	end
	return setmetatable({ check = fn, name = name or "none", names = names }, Gate)
end

-- Whether sends are restricted now, and the reason the client gave, if any.
-- A check that raises an error counts as open: the send result still catches
-- a real restriction.
function Gate:restricted()
	if not self.check then
		return false
	end
	local ok, restricted, reason = pcall(self.check)
	if not ok then
		return false
	end
	return restricted == true, reason
end

-- What a SendAddonMessage result means for the outbox: "ok", "throttle",
-- "lockdown" or "error", and the result's name. Clients that return nothing
-- or true count as ok; false is an error.
function Gate:classify(code)
	if code == nil or code == true or code == 0 then
		return "ok", "Success"
	end
	if code == false then
		return "error", "false"
	end
	local name = self.names[code] or tostring(code)
	local key = lower(name)
	if key == "success" then
		return "ok", name
	elseif find(key, "throttle", 1, true) then
		return "throttle", name
	elseif find(key, "lockdown", 1, true) or find(key, "restrict", 1, true) then
		return "lockdown", name
	end
	return "error", name
end

ns.Gate = Gate
return Gate
