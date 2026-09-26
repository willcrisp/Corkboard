-- Loads shared/test-vectors (see its README.md for the format).
local json = require("dkjson")

local Vectors = {}

function Vectors.load(name)
	local f = assert(io.open("shared/test-vectors/" .. name, "rb"))
	local text = f:read("*a")
	f:close()
	local data, _, err = json.decode(text)
	assert(data, err)
	return data
end

local function fromHex(hex)
	return (hex:gsub("%x%x", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

-- A case's input: input (or the bytes of input_hex), repeated, then append.
function Vectors.input(case)
	local value = case.input
	if case.input_hex then
		value = fromHex(case.input_hex)
	end
	if type(value) == "string" then
		value = value:rep(case["repeat"] or 1) .. (case.append or "")
	end
	return value
end

-- A record case: its input, or the section's base with patch and remove applied.
function Vectors.record(base, case)
	if case.input ~= nil then
		return case.input
	end
	local t = {}
	for k, v in pairs(base) do
		t[k] = v
	end
	for k, v in pairs(case.patch or {}) do
		t[k] = v
	end
	for _, k in ipairs(case.remove or {}) do
		t[k] = nil
	end
	return t
end

function Vectors.copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

return Vectors
