-- The vendored LibSerialize and LibDeflate, loaded outside the game for the
-- wire and sync specs. They only need LibStub.
local Libs = {}

local cached

function Libs.load()
	if cached then
		return cached.serialize, cached.deflate
	end
	local env = setmetatable({}, { __index = _G })
	env._G = env
	for _, file in ipairs({
		"addon/Corkboard/Libs/LibStub/LibStub.lua",
		"addon/Corkboard/Libs/LibDeflate/LibDeflate.lua",
		"addon/Corkboard/Libs/LibSerialize/LibSerialize.lua",
	}) do
		local chunk = assert(loadfile(file))
		setfenv(chunk, env)
		chunk()
	end
	cached = { serialize = env.LibStub("LibSerialize"), deflate = env.LibStub("LibDeflate") }
	return cached.serialize, cached.deflate
end

-- A Wire over the real libraries.
function Libs.wire()
	local Wire = require("Core.Wire")
	return Wire.new(Libs.load())
end

return Libs
