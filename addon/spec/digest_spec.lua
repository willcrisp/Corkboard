local Digest = require("Core.Digest")
local Vectors = require("helpers.vectors")

local vectors = Vectors.load("digest.json")

describe("Digest vectors", function()
	for _, case in ipairs(vectors.bucket) do
		it("bucket(" .. case.id .. ")", function()
			assert.are.equal(case.bucket, Digest.bucket(case.id))
		end)
	end

	for _, case in ipairs(vectors.line) do
		it("line for " .. case.note.id, function()
			assert.are.equal(case.line, Digest.line(case.note))
		end)
	end

	for _, case in ipairs(vectors.boards) do
		it(case.name, function()
			local result = Digest.compute(case.notes)
			assert.are.equal(case.count, result.count)
			assert.are.same(case.buckets, result.buckets)
			assert.are.equal(case.digest, result.digest)
		end)

		it(case.name .. " (notes as a map)", function()
			local byId = {}
			for _, note in ipairs(case.notes) do
				byId[note.id] = note
			end
			assert.are.equal(case.digest, Digest.compute(byId).digest)
		end)
	end
end)

describe("Digest", function()
	it("has 32 buckets", function()
		assert.are.equal(32, #Digest.compute({}).buckets)
	end)

	it("combines the bucket hashes it computed", function()
		local result = Digest.compute(vectors.boards[#vectors.boards].notes)
		assert.are.equal(result.digest, Digest.combine(result.buckets))
	end)

	it("changes when a note's rev or editor changes, not its text", function()
		local note = Vectors.copy(vectors.line[1].note)
		local before = Digest.compute({ note }).digest
		note.text = "different text"
		assert.are.equal(before, Digest.compute({ note }).digest)
		note.rev = note.rev + 1
		assert.are_not.equal(before, Digest.compute({ note }).digest)
	end)

	describe("mismatched", function()
		it("lists differing buckets, 0-based and ascending", function()
			local a, b = {}, {}
			for i = 1, 32 do
				a[i], b[i] = i, i
			end
			b[1], b[17], b[32] = 0, 0, 0
			assert.are.same({ 0, 16, 31 }, Digest.mismatched(a, b))
		end)

		it("is empty for equal boards", function()
			local notes = vectors.boards[#vectors.boards].notes
			local a, b = Digest.compute(notes), Digest.compute(notes)
			assert.are.same({}, Digest.mismatched(a.buckets, b.buckets))
		end)

		it("pinpoints the bucket of a changed note", function()
			local notes = vectors.boards[#vectors.boards].notes
			local before = Digest.compute(notes).buckets
			local changed = {}
			for i, note in ipairs(notes) do
				changed[i] = note
			end
			changed[1] = Vectors.copy(notes[1])
			changed[1].rev = changed[1].rev + 1
			local after = Digest.compute(changed).buckets
			assert.are.same({ Digest.bucket(notes[1].id) }, Digest.mismatched(before, after))
		end)
	end)
end)
