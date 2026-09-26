-- Run from the repo root by test_sync.py: logs a fake client into the real
-- addon with a SavedVariables file and a Corkboard_Cloud/Data.lua written by
-- the companion, then prints the boards as JSON.
--   lua5.1 companion/tests/load_cloud.lua <SavedVariables file> <Data.lua>
package.path = "addon/Corkboard/?.lua;addon/spec/?.lua;" .. package.path
local Client = require("helpers.client")
local json = require("dkjson")

local function read(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	return text
end

local client = Client.new({ saved = read(arg[1]), cloud = read(arg[2]), name = "Will", realm = "Realm" }):login()
io.write(json.encode(client.env.CorkboardDB.global.boards))
