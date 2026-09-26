-- The shared sanitiser fuzz corpus (docs/design.md §12 Phase 4): the Lua
-- sanitiser must give the Python one's answer for every case.
local Sanitise = require("Core.Sanitise")
local Vectors = require("helpers.vectors")

local corpus = Vectors.load("sanitise_fuzz.json")

describe("Sanitise fuzz corpus", function()
	it("matches Python on every text case", function()
		local mismatches = {}
		for i, case in ipairs(corpus.text) do
			local ok, reason = Sanitise.text(Vectors.input(case))
			if ok ~= case.ok or reason ~= case.reason then
				mismatches[#mismatches + 1] = ("#%d %s: Lua %s/%s, Python %s/%s"):format(i, case.input_hex,
					tostring(ok), tostring(reason), tostring(case.ok), tostring(case.reason))
			end
		end
		assert.are.same({}, mismatches)
		assert.is_true(#corpus.text >= 500)
	end)

	it("matches Python on every name and board name", function()
		for i, case in ipairs(corpus.name) do
			assert.are.equal(case.ok, Sanitise.name(Vectors.input(case)), "name #" .. i)
		end
		for i, case in ipairs(corpus.board_name) do
			assert.are.equal(case.ok, Sanitise.boardName(Vectors.input(case)), "board name #" .. i)
		end
	end)
end)
