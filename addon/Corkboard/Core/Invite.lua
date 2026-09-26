-- Invite strings (docs/design.md §9): CORK1:<base64(boardId|secret|ownerName)>.
-- Pure Lua 5.1. shared/test-vectors/invite.json pins the format.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Sanitise = ns.Sanitise or require("Core.Sanitise")

local byte, char, find, gsub, match, sub = string.byte, string.char, string.find, string.gsub, string.match, string.sub
local floor = math.floor
local concat = table.concat

local Invite = {}

Invite.PREFIX = "CORK1:"
Invite.ID = "^[0-9a-z]+$"
Invite.ID_LENGTH = 16
Invite.SECRET = "^[0-9A-Za-z]+$"
Invite.SECRET_MIN, Invite.SECRET_MAX = 16, 64

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = {}
for i = 1, 64 do
	DECODE[byte(ALPHABET, i)] = i - 1
end

-- Standard base64 with "=" padding.
function Invite.base64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local k1, k2 = floor(n / 262144), floor(n / 4096) % 64
		local k3, k4 = floor(n / 64) % 64, n % 64
		out[#out + 1] = sub(ALPHABET, k1 + 1, k1 + 1)
			.. sub(ALPHABET, k2 + 1, k2 + 1)
			.. (b and sub(ALPHABET, k3 + 1, k3 + 1) or "=")
			.. (c and sub(ALPHABET, k4 + 1, k4 + 1) or "=")
	end
	return concat(out)
end

-- Decodes base64, with or without its "=" padding. Returns nil for anything
-- that isn't strictly base64.
function Invite.unbase64(s)
	s = gsub(s, "=+$", "")
	if #s % 4 == 1 or find(s, "[^A-Za-z0-9+/]") then
		return nil
	end
	local out = {}
	for i = 1, #s, 4 do
		local k = { byte(s, i, i + 3) }
		local n, count = 0, #k
		for j = 1, 4 do
			n = n * 64 + (k[j] and DECODE[k[j]] or 0)
		end
		local a, b, c = floor(n / 65536), floor(n / 256) % 256, n % 256
		if count == 2 then
			out[#out + 1] = char(a)
		elseif count == 3 then
			out[#out + 1] = char(a, b)
		else
			out[#out + 1] = char(a, b, c)
		end
	end
	return concat(out)
end

function Invite.validId(id)
	return type(id) == "string" and #id == Invite.ID_LENGTH and find(id, Invite.ID) ~= nil
end

function Invite.validSecret(secret)
	return type(secret) == "string"
		and #secret >= Invite.SECRET_MIN
		and #secret <= Invite.SECRET_MAX
		and find(secret, Invite.SECRET) ~= nil
end

-- The invite for a board.
function Invite.encode(board)
	return Invite.PREFIX .. Invite.base64(board.id .. "|" .. board.secret .. "|" .. board.owner)
end

-- Parses a pasted invite. Surrounding spaces are ignored, and so is case in
-- "CORK1:". Returns { id, secret, owner }, or nil and a reason: "invite"
-- when it isn't a Corkboard invite at all, "invite_version" for a newer
-- format, or "invite_corrupt" when it's damaged.
function Invite.decode(s)
	if type(s) ~= "string" then
		return nil, "invite"
	end
	s = match(s, "^%s*(.-)%s*$")
	local version, body = match(s, "^[Cc][Oo][Rr][Kk](%d+):(.*)$")
	if not version then
		return nil, "invite"
	end
	if version ~= "1" then
		return nil, "invite_version"
	end
	local raw = Invite.unbase64(body)
	if not raw then
		return nil, "invite_corrupt"
	end
	local id, secret, owner = match(raw, "^([^|]*)|([^|]*)|(.*)$")
	if not id or not Invite.validId(id) or not Invite.validSecret(secret) or not Sanitise.name(owner) then
		return nil, "invite_corrupt"
	end
	return { id = id, secret = secret, owner = owner }
end

ns.Invite = Invite
return Invite
