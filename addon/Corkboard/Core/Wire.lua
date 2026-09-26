-- The wire format (docs/design.md §5.2). Pure Lua 5.1: LibSerialize and
-- LibDeflate come in through Wire.new, so busted can pass the real libraries
-- or stand-ins.
--
-- An envelope { v = 1, t = <type>, b = boardId, ... } is serialized with
-- LibSerialize, compressed with LibDeflate's CompressDeflate, and encoded with
-- EncodeForWoWAddonChannel, which leaves no "\0" bytes. That text is split
-- into chunks of at most 255 bytes, one addon message each. Every chunk starts
-- with two bytes: its index and the chunk count, both 1-250. So a receiver
-- can tell a missing or repeated chunk, which raw deflate data (no checksum)
-- wouldn't show.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Invite = ns.Invite or require("Core.Invite")

local byte, char, sub = string.byte, string.char, string.sub
local ceil = math.ceil
local concat = table.concat

local Wire = {}

Wire.VERSION = 1
Wire.PREFIX = "CORK"
Wire.MESSAGE = 255 -- bytes per addon message
Wire.CHUNK = Wire.MESSAGE - 2 -- payload per chunk, after the header
Wire.MAX_CHUNKS = 32 -- about 8 KB of wire text per envelope; more is dropped
Wire.TYPES = { HELLO = true, IDX = true, NEED = true, PUT = true, MEMBERS = true, META = true }

Wire.__index = Wire

-- serializer: LibSerialize (or anything with :Serialize and :Deserialize).
-- deflate: LibDeflate (:CompressDeflate, :DecompressDeflate,
-- :EncodeForWoWAddonChannel, :DecodeForWoWAddonChannel).
function Wire.new(serializer, deflate)
	return setmetatable({ serializer = serializer, deflate = deflate }, Wire)
end

-- Whether a decoded value is an envelope this client understands. The
-- handlers check each type's own fields.
function Wire.valid(envelope)
	return type(envelope) == "table"
		and envelope.v == Wire.VERSION
		and Wire.TYPES[envelope.t] == true
		and Invite.validId(envelope.b)
end

function Wire:encode(envelope)
	local deflate = self.deflate
	return deflate:EncodeForWoWAddonChannel(deflate:CompressDeflate(self.serializer:Serialize(envelope)))
end

-- Returns the envelope, or nil and a reason: "decode", "inflate",
-- "deserialize" or "envelope".
function Wire:decode(text)
	local deflate = self.deflate
	local compressed = deflate:DecodeForWoWAddonChannel(text)
	if not compressed then
		return nil, "decode"
	end
	local raw = deflate:DecompressDeflate(compressed)
	if not raw then
		return nil, "inflate"
	end
	local ok, envelope = self.serializer:Deserialize(raw)
	if not ok then
		return nil, "deserialize"
	end
	if not Wire.valid(envelope) then
		return nil, "envelope"
	end
	return envelope
end

-- How many addon messages a wire text needs.
function Wire.chunks(text)
	return math.max(1, ceil(#text / Wire.CHUNK))
end

-- Splits a wire text into addon messages. Returns nil when it needs more
-- than Wire.MAX_CHUNKS.
function Wire.split(text)
	local count = Wire.chunks(text)
	if count > Wire.MAX_CHUNKS then
		return nil
	end
	local out = {}
	for i = 1, count do
		out[i] = char(i, count) .. sub(text, (i - 1) * Wire.CHUNK + 1, i * Wire.CHUNK)
	end
	return out
end

-- Reassembly -----------------------------------------------------------------
-- One buffer per key (sender, chat type and channel). A chunk that doesn't
-- follow on from its buffer drops the buffer, so a lost chunk costs the whole
-- message rather than corrupting it.

local Reassembler = {}
Reassembler.__index = Reassembler
Wire.Reassembler = Reassembler

Reassembler.TIMEOUT = 60 -- seconds a partial message is kept
Reassembler.MAX_PENDING = 64

function Reassembler.new()
	return setmetatable({ pending = {}, count = 0 }, Reassembler)
end

function Reassembler:drop(key)
	if self.pending[key] then
		self.pending[key] = nil
		self.count = self.count - 1
	end
end

-- Forgets partial messages older than TIMEOUT, and the oldest ones beyond
-- MAX_PENDING.
function Reassembler:expire(now)
	for key, buffer in pairs(self.pending) do
		if now - buffer.at > Reassembler.TIMEOUT then
			self:drop(key)
		end
	end
	while self.count > Reassembler.MAX_PENDING do
		local oldest, at
		for key, buffer in pairs(self.pending) do
			if not at or buffer.at < at then
				oldest, at = key, buffer.at
			end
		end
		self:drop(oldest)
	end
end

-- Adds one addon message. Returns the whole wire text once its last chunk
-- arrives, otherwise nil.
function Reassembler:add(key, message, now)
	if type(message) ~= "string" or #message < 3 or #message > Wire.MESSAGE then
		return nil
	end
	local index, count = byte(message, 1, 2)
	if count < 1 or count > Wire.MAX_CHUNKS or index < 1 or index > count then
		return nil
	end
	local payload = sub(message, 3)
	if count == 1 then
		return payload
	end
	local buffer = self.pending[key]
	if index == 1 then
		if buffer then
			self:drop(key)
		end
		self.pending[key] = { count = count, parts = { payload }, at = now }
		self.count = self.count + 1
		self:expire(now)
		return nil
	end
	if not buffer or buffer.count ~= count or #buffer.parts + 1 ~= index then
		self:drop(key)
		return nil
	end
	buffer.parts[index] = payload
	buffer.at = now
	if index == count then
		self.pending[key] = nil
		self.count = self.count - 1
		return concat(buffer.parts)
	end
	return nil
end

ns.Wire = Wire
return Wire
