-- Smoke test for CorkSpike2: channel limit, reach, link checks, BNet sizes and the report, against wowmock.
-- Usage from the repo root: lua5.1 spikes/mock/smoke2.lua spikes/CorkSpike2/CorkSpike2.lua
package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;addon/Corkboard/?.lua;" .. package.path
local mock = require("wowmock")

-- The libraries Corkboard carries, and a stand-in Corkboard addon exposing its sanitiser.
_G.LibStub = nil
dofile("addon/Corkboard/Libs/LibStub/LibStub.lua")
dofile("addon/Corkboard/Libs/LibDeflate/LibDeflate.lua")
dofile("addon/Corkboard/Libs/LibSerialize/LibSerialize.lua")
local Sanitise = require("Core.Sanitise")
_G.Corkboard = { Sanitise = Sanitise }
_G.CorkSpike2DB = nil

local chunk = assert(loadfile(arg[1]))
chunk("CorkSpike2", {})
mock.fire("ADDON_LOADED", "CorkSpike2")
mock.fire("PLAYER_LOGIN")
mock.fire("PLAYER_ENTERING_WORLD", true, false)

local function run(command, seconds)
	mock.slash(command, "CORKSPIKETWO")
	mock.advance(seconds)
end

run("", 0)
run("limit", 40)
run("reach CorkReach secretpw", 20)
run("reach off", 1)
_G.ChatFrameUtil.InsertLink("|cffa335ee|Hitem:18832::::::::60:::::::::|h[Brutality Blade]|h|r")
run("capture", 1)
_G.ChatFrameUtil.InsertLink("|cffa335ee|Hitem:18832::::::::60:::::::::|h[Brutality Blade]|h|r")
mock.advance(121)
run("links", 60)
run("bnet 42", 1)
_G.BNSendGameData = function(_, _, text) if #text > 4078 then error("message too long") end end
run("bnetsize", 20)
mock.fire("PLAYER_LOGOUT")
run("report", 0)

local report
for _, f in ipairs(mock.frames()) do
	if f.kind == "EditBox" then report = f.text end
end
print(report)
print("---- chat errors:")
local bad = 0
for _, line in ipairs(mock.chat) do
	if line:find("error in") then print(line); bad = bad + 1 end
end
assert(report and report:find("Spike 04"), "no report")
assert(bad == 0, "the spike raised errors")
assert(report:find("| intact |"), "no link survived the network round trip")
