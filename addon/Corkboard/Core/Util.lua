-- Byte-level helpers shared by the merge core. Pure Lua 5.1: no WoW API, so it
-- runs under busted as well as in game (docs/design.md §11).

local _, ns = ...
ns = type(ns) == "table" and ns or {}

local byte, char, find, format = string.byte, string.char, string.find, string.format
local floor = math.floor

local Util = {}

-- Largest integer a Lua 5.1 number (a double) holds exactly. Revs and
-- timestamps above it are rejected by the sanitiser.
Util.INT_MAX = 9007199254740991 -- 2^53 - 1

-- Three-way byte-wise compare: -1, 0 or 1. Lua's `<` on strings goes through
-- strcoll, so its order depends on the C locale. This doesn't, and for valid
-- UTF-8 it matches Python's code-point order.
function Util.compare(a, b)
	if a == b then
		return 0
	end
	local la, lb = #a, #b
	for i = 1, la < lb and la or lb do
		local x, y = byte(a, i), byte(b, i)
		if x ~= y then
			return x < y and -1 or 1
		end
	end
	return la < lb and -1 or 1
end

function Util.less(a, b)
	return Util.compare(a, b) < 0
end

-- XOR of two nibbles, as a flat table: XOR4[a * 16 + b + 1] = a xor b.
local XOR4 = {}
for a = 0, 15 do
	for b = 0, 15 do
		local r, bit, x, y = 0, 1, a, b
		for _ = 1, 4 do
			if x % 2 ~= y % 2 then
				r = r + bit
			end
			x, y, bit = floor(x / 2), floor(y / 2), bit * 2
		end
		XOR4[a * 16 + b + 1] = r
	end
end

-- 32-bit FNV-1a: for each byte, h = (h xor byte) * 16777619 mod 2^32, from
-- h = 2166136261. Lua 5.1 has no bit operators, so the xor goes through XOR4
-- on the low byte, and the multiply splits the prime into 2^24 + 403 so every
-- intermediate stays below 2^53 and exact.
function Util.fnv1a32(s)
	local h = 2166136261
	for i = 1, #s do
		local c = byte(s, i)
		local lo = h % 256
		h = h - lo + XOR4[floor(lo / 16) * 16 + floor(c / 16) + 1] * 16 + XOR4[lo % 16 * 16 + c % 16 + 1]
		h = (h * 403 + h % 256 * 16777216) % 4294967296
	end
	return h
end

-- A 32-bit unsigned integer as 4 big-endian bytes.
function Util.uint32be(n)
	return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

function Util.isInteger(n, min, max)
	return type(n) == "number" and n % 1 == 0 and n >= min and n <= max
end

-- Decimal form of an integer. tostring() switches to exponent form above
-- 1e14, and "%d" truncates to a C long (32-bit on Windows).
function Util.formatInt(n)
	return format("%.0f", n)
end

-- Strict UTF-8 (RFC 3629): no overlong forms, no surrogates, nothing above
-- U+10FFFF. The same set Python's strict decoder accepts.
function Util.isUtf8(s)
	if not find(s, "[\128-\255]") then
		return true
	end
	local i, len = 1, #s
	while i <= len do
		local c = byte(s, i)
		if c < 0x80 then
			i = i + 1
		else
			local n, lo, hi
			if c >= 0xC2 and c <= 0xDF then
				n, lo, hi = 1, 0x80, 0xBF
			elseif c == 0xE0 then
				n, lo, hi = 2, 0xA0, 0xBF
			elseif c == 0xED then
				n, lo, hi = 2, 0x80, 0x9F
			elseif c >= 0xE1 and c <= 0xEF then
				n, lo, hi = 2, 0x80, 0xBF
			elseif c == 0xF0 then
				n, lo, hi = 3, 0x90, 0xBF
			elseif c == 0xF4 then
				n, lo, hi = 3, 0x80, 0x8F
			elseif c >= 0xF1 and c <= 0xF3 then
				n, lo, hi = 3, 0x80, 0xBF
			else
				return false
			end
			if i + n > len then
				return false
			end
			local c2 = byte(s, i + 1)
			if c2 < lo or c2 > hi then
				return false
			end
			for k = i + 2, i + n do
				local cn = byte(s, k)
				if cn < 0x80 or cn > 0xBF then
					return false
				end
			end
			i = i + n + 1
		end
	end
	return true
end

ns.Util = Util
return Util
