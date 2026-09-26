-- Smoke test for CorkSpike: runs /cspike all, the canary and the report against wowmock.
-- Usage from the repo root: lua5.1 spikes/mock/smoke.lua spikes/CorkSpike/CorkSpike.lua
package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
local mock = require("wowmock")
local chunk = assert(loadfile(arg[1]))
chunk("CorkSpike", {})
mock.fire("ADDON_LOADED", "CorkSpike")
mock.fire("PLAYER_LOGIN")

local function finished()
	for _, line in ipairs(mock.chat) do
		if line:find("finished") or line:find("error in") then return line end
	end
end

mock.slash("")
mock.slash("all")
local elapsed = 0
while not finished() and elapsed < 1200 do
	mock.advance(10)
	elapsed = elapsed + 10
end
print("script ended after ~" .. elapsed .. " s: " .. tostring(finished()))

-- canary with a lockdown in the middle, plus a watch expression
mock.slash("watch C_RestrictedActions.IsAddOnRestrictionActive(1)")
mock.slash("canary on")
mock.advance(5)
mock.locked = true
mock.advance(6)
mock.locked = false
mock.advance(5)
mock.slash("canary off")

mock.slash("report")
local report
for _, f in ipairs(mock.frames()) do
	if f.kind == "EditBox" then report = f.text end
end
print(report)
print("---- chat errors:")
for _, line in ipairs(mock.chat) do
	if line:find("error") then print(line) end
end
