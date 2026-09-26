local Sanitise = require("Core.Sanitise")
local Vectors = require("helpers.vectors")

local vectors = Vectors.load("sanitise.json")

describe("Sanitise.text vectors", function()
	for _, case in ipairs(vectors.text) do
		it(case.name, function()
			local ok, reason = Sanitise.text(Vectors.input(case))
			assert.are.equal(case.ok, ok)
			assert.are.equal(case.reason, reason)
		end)
	end
end)

describe("Sanitise.name vectors", function()
	for _, case in ipairs(vectors.name) do
		it(case.name, function()
			assert.are.equal(case.ok, Sanitise.name(Vectors.input(case)))
		end)
	end
end)

describe("Sanitise.boardName vectors", function()
	for _, case in ipairs(vectors.board_name) do
		it(case.name, function()
			assert.are.equal(case.ok, Sanitise.boardName(Vectors.input(case)))
		end)
	end
end)

local function recordVectors(kind, check)
	describe(("Sanitise.%s vectors"):format(kind), function()
		local section = vectors[kind]
		for _, case in ipairs(section.cases) do
			it(case.name, function()
				local input = Vectors.record(section.base, case)
				local clean, reason = check(input)
				if case.ok then
					assert.is_nil(reason)
					assert.are.same(case.output or input, clean)
					assert.are_not.equal(input, clean) -- a copy, never the caller's table
				else
					assert.is_nil(clean)
					assert.are.equal(case.reason, reason)
				end
			end)
		end
	end)
end

recordVectors("note", Sanitise.note)
recordVectors("member", Sanitise.member)
recordVectors("meta", Sanitise.meta)

describe("Sanitise", function()
	it("allows every link type in the spec", function()
		local types = {}
		for linkType in pairs(Sanitise.LINK_TYPES) do
			types[#types + 1] = linkType
			assert.is_true(Sanitise.text(("|H%s:1|h[x]|h"):format(linkType)))
		end
		table.sort(types)
		assert.are.same(
			{ "achievement", "battlepet", "currency", "enchant", "item", "journal", "mount", "quest", "spell", "trade" },
			types
		)
	end)

	it("accepts a note whose text uses the whole budget", function()
		local note = Vectors.copy(vectors.note.base)
		note.text = ("|cffffffff|Hitem:13444|h[Major Mana Potion]|h|r"):rep(40)
		assert.is_true(#note.text <= Sanitise.MAX_TEXT)
		assert.is_table(Sanitise.note(note))
	end)
end)
