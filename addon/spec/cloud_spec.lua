local Cloud = require("Core.Cloud")
local Store = require("Core.Store")

local T0 = 1790000000

local function newStore()
	local store = Store.new({ global = { boards = {} }, char = {} }, {
		now = function()
			return T0
		end,
		rand = function(n)
			return n
		end,
		me = "Will-Realm",
		prefix = "a1b2c3d4",
	})
	return store, assert(store:createBoard("MC"))
end

local function note(id, rev, text)
	return { id = id, author = "Bob-Realm", created = T0, rev = rev, editor = "Bob-Realm", text = text, color = 1,
		deleted = false }
end

describe("Cloud.load", function()
	it("merges the companion's notes, members and name, and records the sync", function()
		local store, board = newStore()
		local changes = {}
		store:listen(function(c)
			changes[#changes + 1] = c
		end)
		local data = {
			version = 1,
			written = T0 + 50,
			boards = {
				[board.id] = {
					cursor = 42,
					syncedAt = T0 + 40,
					notes = { note("b0b0b0b0-0001", T0 + 5, "from the cloud"), { id = "bad" } },
					members = { { name = "Bob-Realm", role = "member", rev = T0 + 1, editor = "Bob-Realm", removed = false } },
					meta = { name = "MC (cloud)", rev = T0 + 9, editor = "Bob-Realm" },
				},
				unknownboard0000 = { notes = { note("b0b0b0b0-0002", T0, "ignored") } },
			},
		}
		assert.are.same({ boards = 1, notes = 1, dropped = 1 }, Cloud.load(store, data))
		assert.are.equal("from the cloud", board.notes["b0b0b0b0-0001"].text)
		assert.are.equal("MC (cloud)", board.meta.name)
		assert.are.equal(T0 + 40, board.sync.lastCloudAt)
		assert.are.equal(42, board.sync.cloudCursor)
		assert.is_true(changes[1].remote)
		assert.is_nil(store:board("unknownboard0000"))
		-- Loading it again changes nothing: merging is idempotent.
		assert.are.same({ boards = 1, notes = 0, dropped = 1 }, Cloud.load(store, data))
		-- An older file doesn't move the cursor back.
		data.boards[board.id].cursor, data.boards[board.id].syncedAt = 7, T0
		Cloud.load(store, data)
		assert.are.equal(42, board.sync.cloudCursor)
		assert.are.equal(T0 + 40, board.sync.lastCloudAt)
	end)

	it("ignores missing, malformed or newer data", function()
		local store = newStore()
		assert.are.same({ nil, "none" }, { Cloud.load(store, nil) })
		assert.are.same({ nil, "none" }, { Cloud.load(store, { version = 1 }) })
		assert.are.same({ nil, "version" }, { Cloud.load(store, { version = 2, boards = {} }) })
		local _, board = newStore()
		assert.are.same({ boards = 0, notes = 0, dropped = 0 }, Cloud.load(store, { version = 1, boards = {
			[board.id] = "junk" } }))
	end)
end)
