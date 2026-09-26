local Wire = require("Core.Wire")
local Libs = require("helpers.libs")

local BOARD = "k3f9x2m7q1pz8c4w"
local LINK = "|cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r"

local function note(i, text)
	return { id = string.format("a1b2c3d4-%04d", i), author = "Will-Realm", created = 1790000000, rev = 1790000000 + i,
		editor = "Bob-Realm", text = text or ("note " .. i), color = 1 + i % 5, deleted = false }
end

describe("Wire", function()
	local wire = Libs.wire()

	it("round-trips an envelope through LibSerialize and LibDeflate", function()
		local envelope = { v = 1, t = "PUT", b = BOARD, n = { note(1, "Need 4x " .. LINK), note(2) } }
		local text = wire:encode(envelope)
		assert.is_nil(text:find("\0", 1, true))
		assert.are.same(envelope, wire:decode(text))
	end)

	it("keeps links, UTF-8 and every escape byte for byte", function()
		local text = "Ünïcødé ||| " .. LINK .. " |cnIQ4:x|r\n" .. string.rep("é", 300)
		local out = wire:decode(wire:encode({ v = 1, t = "PUT", b = BOARD, n = { note(1, text) } }))
		assert.are.equal(text, out.n[1].text)
	end)

	it("says why it can't decode", function()
		assert.are.same({ nil, "inflate" }, { wire:decode("\255\255\255") })
		local serializer, deflate = Libs.load()
		local function raw(s)
			return deflate:EncodeForWoWAddonChannel(deflate:CompressDeflate(s))
		end
		assert.are.equal("deserialize", select(2, wire:decode(raw("not LibSerialize"))))
		local function wrap(value)
			return raw(serializer:Serialize(value))
		end
		assert.are.equal("envelope", select(2, wire:decode(wrap("a string"))))
		assert.are.equal("envelope", select(2, wire:decode(wrap({ v = 2, t = "PUT", b = BOARD }))))
		assert.are.equal("envelope", select(2, wire:decode(wrap({ v = 1, t = "EVIL", b = BOARD }))))
		assert.are.equal("envelope", select(2, wire:decode(wrap({ v = 1, t = "PUT", b = "short" }))))
	end)

	it("reports a decoder that fails outright", function()
		local broken = Wire.new({}, { DecodeForWoWAddonChannel = function() end })
		assert.are.equal("decode", select(2, broken:decode("x")))
	end)
end)

describe("Wire.split and the reassembler", function()
	local function text(n)
		local out = {}
		for i = 1, n do
			out[i] = string.char(1 + (i * 7) % 250)
		end
		return table.concat(out)
	end

	it("fits one message when it can, with a 2-byte header", function()
		local chunks = Wire.split(text(Wire.CHUNK))
		assert.are.equal(1, #chunks)
		assert.are.equal(Wire.MESSAGE, #chunks[1])
		assert.are.equal("\1\1", chunks[1]:sub(1, 2))
		assert.are.equal(1, Wire.chunks(""))
	end)

	it("splits into numbered chunks that reassemble", function()
		local s = text(Wire.CHUNK * 3 + 10)
		local chunks = Wire.split(s)
		assert.are.equal(4, #chunks)
		local r = Wire.Reassembler.new()
		for i = 1, 3 do
			assert.is_nil(r:add("Bob", chunks[i], 0))
		end
		assert.are.equal(s, r:add("Bob", chunks[4], 0))
		assert.are.equal(0, r.count)
	end)

	it("refuses a text too long to send", function()
		assert.is_nil(Wire.split(text(Wire.CHUNK * Wire.MAX_CHUNKS + 1)))
		assert.are.equal(Wire.MAX_CHUNKS, #Wire.split(text(Wire.CHUNK * Wire.MAX_CHUNKS)))
	end)

	it("keeps senders apart", function()
		local a, b = Wire.split(text(600)), Wire.split(text(400))
		local r = Wire.Reassembler.new()
		assert.is_nil(r:add("A", a[1], 0))
		assert.is_nil(r:add("B", b[1], 0))
		assert.is_nil(r:add("A", a[2], 0))
		assert.are.equal(text(400), r:add("B", b[2], 0))
		assert.are.equal(text(600), r:add("A", a[3], 0))
	end)

	it("drops a message with a missing, repeated or foreign chunk", function()
		local chunks = Wire.split(text(1000))
		local r = Wire.Reassembler.new()
		r:add("A", chunks[1], 0)
		assert.is_nil(r:add("A", chunks[3], 0)) -- chunk 2 lost
		assert.is_nil(r:add("A", chunks[4], 0))
		assert.are.equal(0, r.count)
		r:add("A", chunks[1], 0)
		r:add("A", chunks[2], 0)
		assert.is_nil(r:add("A", chunks[2], 0)) -- repeated
		assert.is_nil(r:add("A", chunks[3], 0))
		local other = Wire.split(text(300))
		r:add("A", chunks[1], 0)
		assert.is_nil(r:add("A", other[2], 0)) -- another message's count
		assert.is_true(r.dropped >= 3)
	end)

	it("restarts on a new first chunk", function()
		local one, two = Wire.split(text(600)), Wire.split(text(500))
		local r = Wire.Reassembler.new()
		r:add("A", one[1], 0)
		r:add("A", two[1], 0)
		assert.are.equal(text(500), r:add("A", two[2], 0))
	end)

	it("ignores malformed messages", function()
		local r = Wire.Reassembler.new()
		assert.is_nil(r:add("A", nil, 0))
		assert.is_nil(r:add("A", "\1\1", 0))
		assert.is_nil(r:add("A", "\3\2xx", 0))
		assert.is_nil(r:add("A", "\1\0xx", 0))
		assert.is_nil(r:add("A", "\1\99xx", 0))
		assert.is_nil(r:add("A", string.rep("x", 256), 0))
		assert.are.equal("xx", r:add("A", "\1\1xx", 0))
	end)

	it("forgets stale partial messages and caps how many it holds", function()
		local chunks = Wire.split(text(600))
		local r = Wire.Reassembler.new()
		r:add("old", chunks[1], 0)
		r:add("new", chunks[1], Wire.Reassembler.TIMEOUT + 1)
		assert.is_nil(r.pending.old)
		for i = 1, Wire.Reassembler.MAX_PENDING + 5 do
			r:add("s" .. i, chunks[1], 100 + i / 10)
		end
		assert.are.equal(Wire.Reassembler.MAX_PENDING, r.count)
		assert.is_nil(r.pending.s1)
		assert.is_table(r.pending["s" .. (Wire.Reassembler.MAX_PENDING + 5)])
	end)
end)
