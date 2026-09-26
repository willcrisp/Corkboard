local Gate = require("Core.Gate")

local RESULTS = { Success = 0, InvalidPrefix = 1, AddonMessageThrottle = 3, NotInGroup = 5, ChannelThrottle = 8,
	GeneralError = 9, AddOnMessageLockdown = 11 }

local function client(globals)
	return function(name)
		return globals[name]
	end
end

describe("Gate", function()
	it("polls C_ChatInfo.InChatMessagingLockdown", function()
		local locked = false
		local gate = Gate.new(client({
			C_ChatInfo = {
				InChatMessagingLockdown = function()
					return locked, locked and 1 or 0
				end,
				AreOutgoingAddonChatMessagesRestricted = function()
					error("not this one")
				end,
			},
		}))
		assert.are.equal("C_ChatInfo.InChatMessagingLockdown", gate.name)
		assert.is_false(gate:restricted())
		locked = true
		assert.are.same({ true, 1 }, { gate:restricted() })
	end)

	-- On 1.60.1 it reads true while idle and sends succeed (spike 01).
	it("never uses AreOutgoingAddonChatMessagesRestricted", function()
		local always = function()
			return true
		end
		local gate = Gate.new(client({ C_ChatInfo = { AreOutgoingAddonChatMessagesRestricted = always },
			AreOutgoingAddonChatMessagesRestricted = always }))
		assert.are.equal("none", gate.name)
		assert.is_false(gate:restricted())
	end)

	it("counts as open when there's no check, or it errors", function()
		local gate = Gate.new(client({}))
		assert.are.equal("none", gate.name)
		assert.is_false(gate:restricted())
		gate = Gate.new(client({ C_ChatInfo = { InChatMessagingLockdown = function()
			error("boom")
		end } }))
		assert.is_false(gate:restricted())
	end)

	it("classifies send results by the client's own names", function()
		local gate = Gate.new(client({ Enum = { SendAddonMessageResult = RESULTS } }))
		assert.are.same({ "ok", "Success" }, { gate:classify(0) })
		assert.are.equal("ok", gate:classify(nil))
		assert.are.equal("ok", gate:classify(true))
		assert.are.equal("error", gate:classify(false))
		assert.are.same({ "throttle", "AddonMessageThrottle" }, { gate:classify(3) })
		assert.are.equal("throttle", gate:classify(8))
		assert.are.same({ "lockdown", "AddOnMessageLockdown" }, { gate:classify(11) })
		assert.are.same({ "error", "NotInGroup" }, { gate:classify(5) })
		assert.are.same({ "error", "42" }, { gate:classify(42) })
	end)

	it("treats a 'restricted' result as lockdown, whatever its number", function()
		local gate = Gate.new(client({ Enum = { SendAddonMessageResult = { Success = 0, AddonMessageRestricted = 12 } } }))
		assert.are.same({ "lockdown", "AddonMessageRestricted" }, { gate:classify(12) })
	end)
end)
