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

-- Adler-32 as in zlib (and LibDeflate:Adler32). The sums stay far below 2^53
-- between reductions, so reducing once per 4,000 bytes is exact.
function Util.adler32(s)
	local a, b = 1, 0
	local len = #s
	local i = 1
	while i <= len do
		local j = i + 3999
		if j > len then
			j = len
		end
		for k = i, j do
			a = a + byte(s, k)
			b = b + a
		end
		a = a % 65521
		b = b % 65521
		i = j + 1
	end
	return b * 65536 + a
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
