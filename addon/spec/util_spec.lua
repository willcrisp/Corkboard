local Util = require("Core.Util")
local Vectors = require("helpers.vectors")

describe("Util.fnv1a32", function()
	for _, case in ipairs(Vectors.load("fnv1a32.json").cases) do
		local input = Vectors.input(case)
		it(("matches the reference for %q (%d bytes)"):format(input:sub(1, 16), #input), function()
			assert.are.equal(case.fnv1a32, Util.fnv1a32(input))
		end)
	end

	it("xors every byte value correctly", function()
		-- One byte from the offset basis exercises the xor on all 256 values.
		local seen = {}
		for c = 0, 255 do
			local h = Util.fnv1a32(string.char(c))
			assert.is_true(h >= 0 and h < 2 ^ 32 and h % 1 == 0)
			assert.is_nil(seen[h])
			seen[h] = true
		end
	end)
end)

describe("Util.compare", function()
	it("orders by byte, not by locale", function()
		assert.are.equal(-1, Util.compare("B", "b"))
		assert.are.equal(-1, Util.compare("Zed", "Øystein"))
		assert.are.equal(1, Util.compare("\255", "\1"))
	end)

	it("puts a prefix first", function()
		assert.are.equal(-1, Util.compare("ab", "abc"))
		assert.are.equal(1, Util.compare("abc", "ab"))
		assert.are.equal(-1, Util.compare("", "a"))
	end)

	it("returns 0 for equal strings", function()
		assert.are.equal(0, Util.compare("", ""))
		assert.are.equal(0, Util.compare("Bob-Realm", "Bob-Realm"))
	end)

	it("backs Util.less", function()
		assert.is_true(Util.less("a", "b"))
		assert.is_false(Util.less("b", "a"))
		assert.is_false(Util.less("a", "a"))
	end)
end)

describe("Util.isInteger", function()
	it("accepts integers in range", function()
		assert.is_true(Util.isInteger(0, 0, 10))
		assert.is_true(Util.isInteger(10, 0, 10))
		assert.is_true(Util.isInteger(Util.INT_MAX, 1, Util.INT_MAX))
	end)

	it("rejects everything else", function()
		assert.is_false(Util.isInteger(11, 0, 10))
		assert.is_false(Util.isInteger(-1, 0, 10))
		assert.is_false(Util.isInteger(1.5, 0, 10))
		assert.is_false(Util.isInteger("1", 0, 10))
		assert.is_false(Util.isInteger(true, 0, 10))
		assert.is_false(Util.isInteger(nil, 0, 10))
		assert.is_false(Util.isInteger(0 / 0, 0, 10))
		assert.is_false(Util.isInteger(math.huge, 0, math.huge))
	end)
end)

describe("Util.formatInt", function()
	it("never uses exponent form", function()
		assert.are.equal("0", Util.formatInt(0))
		assert.are.equal("1790000456", Util.formatInt(1790000456))
		assert.are.equal("9007199254740991", Util.formatInt(Util.INT_MAX))
	end)
end)

describe("Util.uint32be", function()
	it("writes 4 big-endian bytes", function()
		assert.are.equal("\0\0\0\1", Util.uint32be(1))
		assert.are.equal("\1\2\3\4", Util.uint32be(0x01020304))
		assert.are.equal("\255\255\255\255", Util.uint32be(4294967295))
	end)
end)

describe("Util.isUtf8", function()
	it("accepts ASCII and well-formed sequences", function()
		assert.is_true(Util.isUtf8(""))
		assert.is_true(Util.isUtf8("plain"))
		assert.is_true(Util.isUtf8("Café — 🔥"))
		assert.is_true(Util.isUtf8("\244\143\191\191")) -- U+10FFFF
	end)

	it("rejects malformed sequences", function()
		assert.is_false(Util.isUtf8("\195"))
		assert.is_false(Util.isUtf8("\224\128\175")) -- overlong
		assert.is_false(Util.isUtf8("\237\160\128")) -- surrogate
		assert.is_false(Util.isUtf8("\240\128\128\128")) -- overlong four-byte
		assert.is_false(Util.isUtf8("\241\128\40\128")) -- bad third byte
		assert.is_false(Util.isUtf8("\255"))
	end)
end)
