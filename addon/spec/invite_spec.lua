local Invite = require("Core.Invite")
local Vectors = require("helpers.vectors")

describe("Invite vectors", function()
	local v = Vectors.load("invite.json")

	for _, case in ipairs(v.encode) do
		it("encodes: " .. case.name, function()
			assert.are.equal(case.invite, Invite.encode(case.board))
		end)
	end

	for _, case in ipairs(v.decode) do
		it("decodes: " .. case.name, function()
			local out, reason = Invite.decode(case.input)
			if case.ok then
				assert.are.same(case.output, out)
			else
				assert.is_nil(out)
				assert.are.equal(case.reason, reason)
			end
		end)
	end
end)

describe("Invite base64", function()
	it("round-trips every byte and every length", function()
		for n = 0, 40 do
			local bytes = {}
			for i = 1, n do
				bytes[i] = string.char((i * 37 + n) % 256)
			end
			local s = table.concat(bytes)
			local encoded = Invite.base64(s)
			assert.are.equal(0, #encoded % 4)
			assert.are.equal(s, Invite.unbase64(encoded))
			assert.are.equal(s, Invite.unbase64((encoded:gsub("=", ""))))
		end
	end)

	it("matches RFC 4648's examples", function()
		local cases = { [""] = "", f = "Zg==", fo = "Zm8=", foo = "Zm9v", foob = "Zm9vYg==", fooba = "Zm9vYmE=",
			foobar = "Zm9vYmFy" }
		for plain, encoded in pairs(cases) do
			assert.are.equal(encoded, Invite.base64(plain))
			assert.are.equal(plain, Invite.unbase64(encoded))
		end
	end)

	it("rejects anything that isn't base64", function()
		assert.is_nil(Invite.unbase64("Zm9v!"))
		assert.is_nil(Invite.unbase64("Z"))
		assert.is_nil(Invite.unbase64("Zm 9v"))
	end)

	it("rejects non-strings", function()
		assert.are.equal("invite", select(2, Invite.decode(nil)))
		assert.are.equal("invite", select(2, Invite.decode(42)))
	end)
end)
