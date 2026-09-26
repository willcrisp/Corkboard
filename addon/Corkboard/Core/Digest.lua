-- Bucketed board digests (docs/design.md §4.4). Pure Lua 5.1.
--
--   bucket(id)     = Adler32(id) % 32
--   line(note)     = id .. "=" .. rev .. ";" .. editor .. "\n"   (rev in plain decimal)
--   bucketHash[i]  = Adler32(concat of bucket i's lines, sorted byte-wise)
--   boardDigest    = Adler32(bucketHash[0..31], each as 4 big-endian bytes)
--
-- Tombstones are included. Buckets are Lua arrays, so buckets[i + 1] holds
-- bucket i.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")

local adler32 = Util.adler32
local concat, sort = table.concat, table.sort

local Digest = {}

Digest.BUCKETS = 32

function Digest.bucket(id)
	return adler32(id) % Digest.BUCKETS
end

function Digest.line(note)
	return note.id .. "=" .. Util.formatInt(note.rev) .. ";" .. note.editor .. "\n"
end

-- Adler-32 over the bucket hashes, 4 big-endian bytes each.
function Digest.combine(buckets)
	local raw = {}
	for i = 1, Digest.BUCKETS do
		raw[i] = Util.uint32be(buckets[i])
	end
	return adler32(concat(raw))
end

-- notes: a map or list of notes. Returns { digest, buckets, count }, where
-- count includes tombstones.
function Digest.compute(notes)
	local lines = {}
	for i = 1, Digest.BUCKETS do
		lines[i] = {}
	end
	local count = 0
	for _, note in pairs(notes) do
		local bucket = lines[Digest.bucket(note.id) + 1]
		bucket[#bucket + 1] = Digest.line(note)
		count = count + 1
	end
	local buckets = {}
	for i = 1, Digest.BUCKETS do
		sort(lines[i], Util.less)
		buckets[i] = adler32(concat(lines[i]))
	end
	return { digest = Digest.combine(buckets), buckets = buckets, count = count }
end

-- The bucket numbers (0-31, ascending) whose hashes differ.
function Digest.mismatched(a, b)
	local out = {}
	for i = 1, Digest.BUCKETS do
		if a[i] ~= b[i] then
			out[#out + 1] = i - 1
		end
	end
	return out
end

ns.Digest = Digest
return Digest
