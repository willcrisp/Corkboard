local Merge = require("Core.Merge")
local Vectors = require("helpers.vectors")

local vectors = Vectors.load("merge.json")

-- field: "notes" or "members"; key: the field records are keyed by.
local SECTIONS = {
	notes = { key = "id", apply = Merge.applyNote },
	members = { key = "name", apply = Merge.applyMember },
}

local function boardFrom(spec, field, key)
	local board = { clock = spec.clock, [field] = {} }
	for _, record in ipairs(spec[field]) do
		board[field][record[key]] = Vectors.copy(record)
	end
	return board
end

local function byKey(list, key)
	local out = {}
	for _, record in ipairs(list) do
		out[record[key]] = record
	end
	return out
end

local function permutations(list)
	local out = {}
	local function permute(prefix, rest)
		if #rest == 0 then
			out[#out + 1] = prefix
			return
		end
		for i = 1, #rest do
			local nextPrefix, nextRest = { unpack(prefix) }, { unpack(rest) }
			nextPrefix[#nextPrefix + 1] = table.remove(nextRest, i)
			permute(nextPrefix, nextRest)
		end
	end
	permute({}, list)
	return out
end

for field, section in pairs(SECTIONS) do
	describe(("Merge vectors (%s)"):format(field), function()
		for _, case in ipairs(vectors[field]) do
			local expected = byKey(case.expect[field], section.key)

			it(case.name, function()
				local board = boardFrom(case.board, field, section.key)
				local results = {}
				for i, record in ipairs(case.apply) do
					local ok, reason = section.apply(board, record)
					results[i] = ok and "stored" or reason
				end
				assert.are.same(case.results, results)
				assert.are.equal(case.expect.clock, board.clock)
				assert.are.same(expected, board[field])
			end)

			it(case.name .. " (every order, applied twice)", function()
				for _, order in ipairs(permutations(case.apply)) do
					local board = boardFrom(case.board, field, section.key)
					for _ = 1, 2 do
						for _, record in ipairs(order) do
							section.apply(board, record)
						end
					end
					assert.are.equal(case.expect.clock, board.clock)
					assert.are.same(expected, board[field])
				end
			end)
		end
	end)
end

-- Local changes ----------------------------------------------------------------

local T0 = 1790000000
local ID = "a1b2c3d4-0007"

local function newBoard()
	local board = {}
	assert(Merge.createNote(board, { id = ID, author = "Will-Realm", text = "first", color = 2 }, T0))
	return board
end

describe("Merge.nextRev", function()
	it("uses the server time when it's ahead of the clock", function()
		assert.are.equal(T0, Merge.nextRev({ clock = T0 - 10 }, T0))
	end)

	it("uses clock + 1 when the clock has caught up", function()
		assert.are.equal(T0 + 1, Merge.nextRev({ clock = T0 }, T0))
		assert.are.equal(T0 + 51, Merge.nextRev({ clock = T0 + 50 }, T0))
	end)

	it("starts a new board at the server time", function()
		assert.are.equal(T0, Merge.nextRev({}, T0))
	end)
end)

describe("Merge.createNote", function()
	it("makes a live note authored and edited by the creator", function()
		local board = {}
		local note = Merge.createNote(board, { id = ID, author = "Will-Realm", text = "hi" }, T0)
		assert.are.same({
			id = ID,
			author = "Will-Realm",
			created = T0,
			rev = T0,
			editor = "Will-Realm",
			text = "hi",
			color = 1,
			deleted = false,
		}, note)
		assert.are.equal(note, board.notes[ID])
		assert.are.equal(T0, board.clock)
	end)

	it("refuses an id that's already on the board", function()
		local board = newBoard()
		local note, reason = Merge.createNote(board, { id = ID, author = "Bob-Realm", text = "x" }, T0 + 5)
		assert.is_nil(note)
		assert.are.equal("exists", reason)
	end)

	it("refuses text the sanitiser rejects and leaves the clock alone", function()
		local board = { clock = 5 }
		local note, reason = Merge.createNote(board, { id = ID, author = "Will-Realm", text = "|Tx|t" }, T0)
		assert.is_nil(note)
		assert.are.equal("escape", reason)
		assert.are.equal(5, board.clock)
		assert.is_nil(board.notes)
	end)
end)

describe("Merge.editNote", function()
	it("bumps rev past the clock and records the editor", function()
		local board = newBoard()
		local note = Merge.editNote(board, ID, { text = "second" }, "Bob-Realm", T0) -- same second
		assert.are.equal(T0 + 1, note.rev)
		assert.are.equal("Bob-Realm", note.editor)
		assert.are.equal("Will-Realm", note.author)
		assert.are.equal(T0, note.created)
		assert.are.equal("second", note.text)
		assert.are.equal(2, note.color)
		assert.are.equal(T0 + 1, board.clock)
	end)

	it("changes only what it's given", function()
		local board = newBoard()
		local note = Merge.editNote(board, ID, { color = 4 }, "Will-Realm", T0 + 10)
		assert.are.equal("first", note.text)
		assert.are.equal(4, note.color)
		assert.are.equal(T0 + 10, note.rev)
	end)

	it("always beats the version it replaced, even with a clock running ahead", function()
		local board = newBoard()
		Merge.applyNote(board, {
			id = ID,
			author = "Will-Realm",
			created = T0,
			rev = T0 + 3600, -- a peer whose clock is an hour ahead
			editor = "Zed-Realm",
			text = "from the future",
			color = 1,
			deleted = false,
		})
		local before = board.notes[ID]
		local after = Merge.editNote(board, ID, { text = "mine" }, "Amy-Realm", T0 + 1)
		assert.are.equal(1, Merge.compareNote(after, before))
		assert.are.equal(after, board.notes[ID])
	end)

	it("refuses a missing or deleted note", function()
		local board = newBoard()
		assert.are.same({ nil, "missing" }, { Merge.editNote(board, "ffffffff-1", { text = "x" }, "Bob-Realm", T0) })
		Merge.deleteNote(board, ID, "Bob-Realm", T0 + 1)
		assert.are.same({ nil, "deleted" }, { Merge.editNote(board, ID, { text = "x" }, "Bob-Realm", T0 + 2) })
		assert.are.same({ nil, "missing" }, { Merge.editNote({}, ID, { text = "x" }, "Bob-Realm", T0) })
	end)

	it("refuses text the sanitiser rejects", function()
		local board = newBoard()
		local note, reason = Merge.editNote(board, ID, { text = ("x"):rep(2001) }, "Bob-Realm", T0 + 1)
		assert.is_nil(note)
		assert.are.equal("too_long", reason)
		assert.are.equal("first", board.notes[ID].text)
		assert.are.equal(T0, board.clock)
	end)
end)

describe("Merge.deleteNote", function()
	it("leaves a tombstone with the text cleared", function()
		local board = newBoard()
		local tomb = Merge.deleteNote(board, ID, "Bob-Realm", T0 + 7)
		assert.is_true(tomb.deleted)
		assert.are.equal("", tomb.text)
		assert.are.equal(T0 + 7, tomb.rev)
		assert.are.equal("Bob-Realm", tomb.editor)
		assert.are.equal(tomb, board.notes[ID])
	end)

	it("refuses a missing or already deleted note", function()
		local board = newBoard()
		assert.are.same({ nil, "missing" }, { Merge.deleteNote(board, "ffffffff-1", "Bob-Realm", T0) })
		Merge.deleteNote(board, ID, "Bob-Realm", T0 + 1)
		assert.are.same({ nil, "deleted" }, { Merge.deleteNote(board, ID, "Bob-Realm", T0 + 2) })
	end)

	it("keeps the note deleted when a stale copy arrives later", function()
		local board = newBoard()
		local old = Vectors.copy(board.notes[ID])
		Merge.deleteNote(board, ID, "Bob-Realm", T0 + 1)
		assert.are.same({ false, "stale" }, { Merge.applyNote(board, old) })
		assert.is_true(board.notes[ID].deleted)
	end)
end)

describe("Merge.setMember", function()
	it("adds, then removes, a member", function()
		local board = {}
		local added = Merge.setMember(board, "Bob-Realm", "member", false, "Will-Realm", T0)
		assert.are.same(
			{ name = "Bob-Realm", role = "member", rev = T0, editor = "Will-Realm", removed = false },
			added
		)
		local removed = Merge.setMember(board, "Bob-Realm", "member", true, "Will-Realm", T0)
		assert.are.equal(T0 + 1, removed.rev)
		assert.is_true(board.members["Bob-Realm"].removed)
		assert.are.equal(T0 + 1, board.clock)
	end)

	it("refuses a bad role", function()
		local board = {}
		assert.are.same({ nil, "role" }, { Merge.setMember(board, "Bob-Realm", "admin", false, "Will-Realm", T0) })
		assert.is_nil(board.members)
	end)
end)

describe("Merge.applyNotes", function()
	local notes = vectors.notes[#vectors.notes] -- the mixed batch case

	it("returns the ids it stored and the reasons it dropped", function()
		local board = { clock = 0, notes = {} }
		local stored, dropped = Merge.applyNotes(board, notes.apply)
		assert.are.same({ "a1b2c3d4-0007", "a1b2c3d4-0007", "b0b0b0b0-0001" }, stored)
		assert.are.same({ "rev" }, dropped)
	end)

	it("reports a garbage record as dropped", function()
		local board = {}
		local stored, dropped = Merge.applyNotes(board, { 5, "x", {} })
		assert.are.same({}, stored)
		assert.are.same({ "type", "type", "id" }, dropped)
	end)
end)

describe("Merge.applyMembers", function()
	it("merges a list of members", function()
		local board = {}
		local stored, dropped = Merge.applyMembers(board, {
			{ name = "Bob-Realm", role = "member", rev = T0, editor = "Will-Realm", removed = false },
			{ name = "Amy-Realm", role = "owner", rev = T0, editor = "Amy-Realm", removed = false },
			{ name = "Zed-Realm", role = "boss", rev = T0, editor = "Amy-Realm", removed = false },
		})
		assert.are.same({ "Bob-Realm", "Amy-Realm" }, stored)
		assert.are.same({ "role" }, dropped)
		assert.are.equal("owner", board.members["Amy-Realm"].role)
	end)
end)

describe("Merge.applyNote", function()
	it("stores a copy, so later changes to the caller's table don't leak in", function()
		local board = {}
		local note = Vectors.copy(vectors.notes[1].apply[1])
		assert.is_true(Merge.applyNote(board, note))
		note.text = "changed"
		assert.are.equal("note", board.notes[note.id].text)
	end)
end)
