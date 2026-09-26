local Store = require("Core.Store")
local Merge = require("Core.Merge")
local Sanitise = require("Core.Sanitise")
local Invite = require("Core.Invite")

local T0 = 1790000000
local ME = "Will-Realm"
local PREFIX = "a1b2c3d4"

-- Park-Miller: the same sequence on every platform.
local function prng(seed)
	local state = seed % 2147483646 + 1
	return function(n)
		state = state * 16807 % 2147483647
		return state % n + 1
	end
end

-- A store over plain tables shaped like AceDB's, with a clock the test moves.
local function newStore(overrides)
	local db = { global = { boards = {} }, char = {} }
	local env = { now = function() return T0 end, rand = prng(1), me = ME, prefix = PREFIX }
	for k, v in pairs(overrides or {}) do
		env[k] = v
	end
	return Store.new(db, env), db, env
end

local function note(id, fields)
	local t = { id = id, author = ME, created = T0, rev = T0, editor = ME, text = "x", color = 1, deleted = false }
	for k, v in pairs(fields or {}) do
		t[k] = v
	end
	return t
end

describe("Store.notePrefix", function()
	it("is 8 lower-case hex digits of FNV-1a over the GUID", function()
		-- Expected values from a Python FNV-1a reference.
		assert.are.equal("6f97d8db", Store.notePrefix("Player-4372-0ABCDEF0"))
		assert.are.equal("6e97d748", Store.notePrefix("Player-4372-0ABCDEF1"))
	end)

	it("pads to 8 digits", function()
		for i = 1, 200 do
			local prefix = Store.notePrefix("Player-1-" .. i)
			assert.is_truthy(prefix:match("^[0-9a-f]+$"))
			assert.are.equal(8, #prefix)
		end
	end)
end)

describe("Store.nextNoteId", function()
	it("starts at 0001", function()
		assert.are.equal("a1b2c3d4-0001", Store.nextNoteId({}, PREFIX))
		assert.are.equal("a1b2c3d4-0001", Store.nextNoteId({ notes = {} }, PREFIX))
	end)

	it("is one more than the highest counter for the prefix, tombstones included", function()
		local board = { notes = {} }
		for _, record in ipairs({
			note("a1b2c3d4-0001"),
			note("a1b2c3d4-0003"),
			note("a1b2c3d4-0005", { deleted = true, text = "" }),
			note("ffffffff-0042"), -- someone else's prefix
		}) do
			board.notes[record.id] = record
		end
		assert.are.equal("a1b2c3d4-0006", Store.nextNoteId(board, PREFIX))
		assert.are.equal("ffffffff-0043", Store.nextNoteId(board, "ffffffff"))
		assert.are.equal("00000000-0001", Store.nextNoteId(board, "00000000"))
	end)

	it("reads counters as numbers, whatever their padding", function()
		local board = { notes = { ["a1b2c3d4-7"] = note("a1b2c3d4-7"), ["a1b2c3d4-0012"] = note("a1b2c3d4-0012") } }
		assert.are.equal("a1b2c3d4-0013", Store.nextNoteId(board, PREFIX))
		board.notes["a1b2c3d4-123456"] = note("a1b2c3d4-123456")
		assert.are.equal("a1b2c3d4-123457", Store.nextNoteId(board, PREFIX))
	end)

	it("produces ids the sanitiser accepts, up to the last counter", function()
		local board = { notes = { ["a1b2c3d4-999999998"] = note("a1b2c3d4-999999998") } }
		local id = Store.nextNoteId(board, PREFIX)
		assert.are.equal("a1b2c3d4-999999999", id)
		assert.is_table(Sanitise.note(note(id)))
		board.notes[id] = note(id)
		assert.are.same({ nil, "id_space" }, { Store.nextNoteId(board, PREFIX) })
	end)

	it("doesn't reuse an id when one character plays on two installs", function()
		-- The counter comes from the board, so once install B has seen A's
		-- note it moves past it. A per-install counter would give B 0001 again.
		local a = newStore()
		local b, bdb = newStore()
		local board = assert(a:createBoard("MC"))
		bdb.global.boards[board.id] = { id = board.id, clock = 0, notes = {}, members = {} }
		local first = assert(a:addNote(board.id, "from install A"))
		Merge.applyNotes(bdb.global.boards[board.id], { first })
		local second = assert(b:addNote(board.id, "from install B"))
		assert.are.equal("a1b2c3d4-0001", first.id)
		assert.are.equal("a1b2c3d4-0002", second.id)
	end)
end)

describe("Store boards", function()
	it("creates a board owned by the player and selects it", function()
		local store, db = newStore()
		local board = assert(store:createBoard("Molten Core prep"))
		assert.are.equal(board, db.global.boards[board.id])
		assert.are.equal(board.id, db.char.current)
		assert.is_truthy(board.id:match("^[0-9a-z]+$"))
		assert.are.equal(Store.ID_LENGTH, #board.id)
		assert.is_truthy(board.secret:match("^[0-9a-z]+$"))
		assert.are.equal(Store.SECRET_LENGTH, #board.secret)
		assert.are.equal(ME, board.owner)
		assert.are.equal(T0, board.created)
		assert.are.same({ name = "Molten Core prep", rev = T0, editor = ME }, board.meta)
		assert.are.same(
			{ [ME] = { name = ME, role = "owner", rev = T0 + 1, editor = ME, removed = false } },
			board.members
		)
		assert.are.equal(T0 + 1, board.clock)
		assert.are.same({}, board.notes)
		assert.is_true(board.cloud)
		assert.is_false(board.guild)
	end)

	it("gives each board its own id and secret", function()
		local store = newStore()
		local a, b = assert(store:createBoard("A")), assert(store:createBoard("B"))
		assert.are_not.equal(a.id, b.id)
		assert.are_not.equal(a.secret, b.secret)
	end)

	it("draws a new id if the first one is taken", function()
		local store, db = newStore({ rand = prng(7) })
		local taken = Store.randomString(prng(7), Store.ID_LENGTH)
		db.global.boards[taken] = { id = taken }
		local board = assert(store:createBoard("MC"))
		assert.are_not.equal(taken, board.id)
		assert.are.equal(taken, db.global.boards[taken].id)
	end)

	it("refuses a bad name and stores nothing", function()
		local store, db = newStore()
		assert.are.same({ nil, "name" }, { store:createBoard("MC|r") })
		assert.are.same({ nil, "name" }, { store:createBoard("  ") })
		assert.are.same({}, db.global.boards)
		assert.is_nil(db.char.current)
	end)

	it("needs to know who the player is", function()
		local store, db = newStore({ me = false })
		assert.are.same({ nil, "identity" }, { store:createBoard("MC") })
		store.env.me, store.env.prefix = ME, nil
		assert.are.same({ nil, "identity" }, { store:createBoard("MC") })
		assert.are.same({}, db.global.boards)
	end)

	it("renames through the merge core", function()
		local now = T0
		local store = newStore({ now = function() return now end })
		local board = assert(store:createBoard("MC"))
		local meta = assert(store:renameBoard(board.id, "BWL"))
		assert.are.same({ name = "BWL", rev = T0 + 2, editor = ME }, meta) -- same second: clock + 1
		assert.are.equal(meta, board.meta)
		now = T0 + 100
		store.env.me = "Bob-Realm"
		meta = assert(store:renameBoard(board.id, "AQ"))
		assert.are.same({ name = "AQ", rev = T0 + 100, editor = "Bob-Realm" }, meta)
	end)

	it("keeps the old name when a rename is refused", function()
		local store = newStore()
		local board = assert(store:createBoard("MC"))
		assert.are.same({ nil, "name" }, { store:renameBoard(board.id, ("x"):rep(65)) })
		assert.are.equal("MC", board.meta.name)
		assert.are.same({ nil, "missing" }, { store:renameBoard("nope", "AQ") })
		store.env.me = nil
		assert.are.same({ nil, "identity" }, { store:renameBoard(board.id, "AQ") })
	end)

	it("deletes a board from this account and clears the selection", function()
		local store, db = newStore()
		local keep = assert(store:createBoard("Keep"))
		local drop = assert(store:createBoard("Drop"))
		assert.are.equal(drop, store:deleteBoard(drop.id))
		assert.is_nil(db.global.boards[drop.id])
		assert.is_nil(db.char.current)
		assert.are.equal(keep, db.global.boards[keep.id])
		assert.are.same({ nil, "missing" }, { store:deleteBoard(drop.id) })
	end)

	it("keeps the selection when deleting another board", function()
		local store, db = newStore()
		local other = assert(store:createBoard("Other"))
		local selected = assert(store:createBoard("Selected"))
		store:deleteBoard(other.id)
		assert.are.equal(selected.id, db.char.current)
	end)

	it("lists boards by name, ignoring ASCII case, then by id", function()
		local store = newStore()
		for _, name in ipairs({ "b", "C", "a", "B" }) do
			assert(store:createBoard(name))
		end
		local names = {}
		for i, board in ipairs(store:boards()) do
			names[i] = Store.name(board)
		end
		assert.are.equal("a", names[1])
		assert.are.equal("C", names[4])
		local middle = { names[2], names[3] }
		table.sort(middle)
		assert.are.same({ "B", "b" }, middle) -- "b" and "B" tie on name...
		local list = store:boards()
		assert.is_true(list[2].id < list[3].id) -- ...so they go by id
	end)

	it("falls back to the id for a board without a name", function()
		assert.are.equal("abc", Store.name({ id = "abc" }))
	end)

	it("tracks the current board", function()
		local store, db = newStore()
		assert.is_nil(store:current())
		local a = assert(store:createBoard("A"))
		local b = assert(store:createBoard("B"))
		assert.are.equal(b, store:current())
		assert.are.equal(a, store:select(a.id))
		assert.are.equal(a, store:current())
		assert.are.same({ nil, "missing" }, { store:select("nope") })
		assert.are.equal(a.id, db.char.current)
		db.char.current = "gone"
		assert.is_nil(store:current())
	end)

end)

describe("Store notes", function()
	local store, board, now
	before_each(function()
		now = T0
		store = newStore({ now = function() return now end })
		board = assert(store:createBoard("MC"))
	end)

	it("adds a note through the merge core with a board-derived id", function()
		local first = assert(store:addNote(board.id, "Need 4x flasks"))
		assert.are.same({
			id = "a1b2c3d4-0001",
			author = ME,
			created = T0,
			rev = T0 + 2,
			editor = ME,
			text = "Need 4x flasks",
			color = 1,
			deleted = false,
		}, first)
		assert.are.equal(first, board.notes[first.id])
		local second = assert(store:addNote(board.id, "and a feast", 3))
		assert.are.equal("a1b2c3d4-0002", second.id)
		assert.are.equal(3, second.color)
		assert.are.equal(T0 + 3, board.clock)
	end)

	it("refuses text the sanitiser rejects and leaves the board alone", function()
		local clock = board.clock
		assert.are.same({ nil, "escape" }, { store:addNote(board.id, "|TInterface\\Icons\\x:0|t") })
		assert.are.same({ nil, "too_long" }, { store:addNote(board.id, ("x"):rep(2001)) })
		assert.are.same({ nil, "link_type" }, { store:addNote(board.id, "|Hunit:Creature-0|h[x]|h") })
		assert.are.same({ nil, "color" }, { store:addNote(board.id, "x", 9) })
		assert.are.same({}, board.notes)
		assert.are.equal(clock, board.clock)
	end)

	it("keeps item links intact", function()
		local text = "Need 4x |cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r for MC"
		assert.are.equal(text, assert(store:addNote(board.id, text)).text)
	end)

	it("edits and deletes as the current player", function()
		local added = assert(store:addNote(board.id, "first"))
		now = T0 + 60
		store.env.me = "Bob-Realm"
		local edited = assert(store:editNote(board.id, added.id, { text = "second", color = 2 }))
		assert.are.equal("Bob-Realm", edited.editor)
		assert.are.equal(ME, edited.author)
		assert.are.equal(T0 + 60, edited.rev)
		assert.are.equal(2, edited.color)
		now = T0 + 61
		local tomb = assert(store:deleteNote(board.id, added.id))
		assert.is_true(tomb.deleted)
		assert.are.equal("", tomb.text)
		assert.are.equal(tomb, board.notes[added.id])
		assert.are.same({ nil, "deleted" }, { store:editNote(board.id, added.id, { text = "x" }) })
		assert.are.same({ nil, "deleted" }, { store:deleteNote(board.id, added.id) })
	end)

	it("counts past its own tombstones", function()
		local added = assert(store:addNote(board.id, "first"))
		assert(store:deleteNote(board.id, added.id))
		assert.are.equal("a1b2c3d4-0002", assert(store:addNote(board.id, "second")).id)
	end)

	it("reports a missing board or note, or an unknown player", function()
		assert.are.same({ nil, "missing" }, { store:addNote("nope", "x") })
		assert.are.same({ nil, "missing" }, { store:editNote("nope", "a1b2c3d4-0001", { text = "x" }) })
		assert.are.same({ nil, "missing" }, { store:deleteNote("nope", "a1b2c3d4-0001") })
		assert.are.same({ nil, "missing" }, { store:editNote(board.id, "a1b2c3d4-0001", { text = "x" }) })
		store.env.prefix = nil
		assert.are.same({ nil, "identity" }, { store:addNote(board.id, "x") })
		assert.are.same({ nil, "identity" }, { store:editNote(board.id, "a1b2c3d4-0001", { text = "x" }) })
		assert.are.same({ nil, "identity" }, { store:deleteNote(board.id, "a1b2c3d4-0001") })
	end)

	it("runs out of ids gracefully", function()
		board.notes["a1b2c3d4-999999999"] = note("a1b2c3d4-999999999")
		assert.are.same({ nil, "id_space" }, { store:addNote(board.id, "x") })
	end)

	it("lists live notes oldest first", function()
		local a = assert(store:addNote(board.id, "a"))
		now = T0 + 10
		local b = assert(store:addNote(board.id, "b"))
		local c = assert(store:addNote(board.id, "c")) -- same second as b: ordered by id
		now = T0 + 5
		local d = assert(store:addNote(board.id, "d"))
		assert(store:deleteNote(board.id, a.id))
		local list = Store.notes(board)
		assert.are.same({ d.id, b.id, c.id }, { list[1].id, list[2].id, list[3].id })
		assert.are.same({}, Store.notes({}))
	end)

	it("only ever stores records a peer would accept", function()
		local rand = prng(42)
		local ids = {}
		for step = 1, 300 do
			now = T0 + step
			local r = rand(4)
			if r == 1 or #ids == 0 then
				ids[#ids + 1] = assert(store:addNote(board.id, "note " .. step, rand(5))).id
			elseif r == 2 then
				assert(store:editNote(board.id, ids[rand(#ids)], { text = "edit " .. step }))
			elseif r == 3 then
				local i = rand(#ids)
				assert(store:deleteNote(board.id, table.remove(ids, i)))
			else
				assert(store:renameBoard(board.id, "name " .. step))
			end
		end
		for _, record in pairs(board.notes) do
			assert.are.same(record, Sanitise.note(record))
			assert.is_true(record.rev <= board.clock)
		end
		assert.are.same(board.meta, Sanitise.meta(board.meta))
	end)
end)

describe("Store sharing", function()
	local function owned()
		local store, db, env = newStore()
		local changes = {}
		store:listen(function(change)
			changes[#changes + 1] = change
		end)
		local board = assert(store:createBoard("MC"))
		return store, board, changes, db, env
	end

	local function kinds(changes)
		local out = {}
		for i, c in ipairs(changes) do
			out[i] = c.kind .. (c.remote and "*" or "")
		end
		return out
	end

	it("notifies listeners of every local change", function()
		local store, board, changes = owned()
		local added = assert(store:addNote(board.id, "hi"))
		assert(store:editNote(board.id, added.id, { text = "there" }))
		assert(store:deleteNote(board.id, added.id))
		assert(store:renameBoard(board.id, "MC2"))
		assert.is_nil(store:editNote(board.id, added.id, { text = "gone" }))
		store:deleteBoard(board.id)
		assert.are.same({ "board", "note", "note", "note", "meta", "deleted" }, kinds(changes))
		assert.are.same({ added.id }, changes[2].keys)
	end)

	it("makes an invite and joins from it", function()
		local _, board = owned()
		local invite = Invite.encode(board)
		assert.are.same({ id = board.id, secret = board.secret, owner = ME }, Invite.decode(invite))

		local other, db = newStore({ me = "Bob-Realm", prefix = "b0b0b0b0" })
		local joined, new = other:joinBoard("  " .. invite .. "  ")
		assert.is_true(new)
		assert.are.equal(board.id, joined.id)
		assert.are.equal(board.secret, joined.secret)
		assert.are.equal(ME, joined.owner)
		assert.are.equal(board.id, db.char.current)
		assert.is_true(joined.cloud)
		assert.is_false(joined.guild)
		assert.are.same({ name = "Bob-Realm", role = "member", rev = T0, editor = "Bob-Realm", removed = false },
			joined.members["Bob-Realm"])
		assert.are.equal(board.id, Store.name(joined)) -- the name arrives with the first HELLO
	end)

	it("joining again changes nothing, unless the secret changed", function()
		local store, board = owned()
		local invite = Invite.encode(board)
		local other = newStore({ me = "Bob-Realm", prefix = "b0b0b0b0" })
		local joined = other:joinBoard(invite)
		local rev = joined.members["Bob-Realm"].rev
		local again, new = other:joinBoard(invite)
		assert.are.equal(joined, again)
		assert.is_false(new)
		assert.are.equal(rev, joined.members["Bob-Realm"].rev)
		assert(store:rotateSecret(board.id))
		other:joinBoard(Invite.encode(board))
		assert.are.equal(board.secret, joined.secret)
		assert.are.same({ Invite.decode(invite).secret }, joined.oldSecrets)
	end)

	it("the owner rejoining keeps the owner role", function()
		local store, board = owned()
		board.members[ME] = nil
		store:joinBoard(Invite.encode(board))
		assert.are.equal("owner", board.members[ME].role)
	end)

	it("refuses bad invites, and joins before the character is known", function()
		local store = newStore()
		assert.are.same({ nil, "invite" }, { store:joinBoard("nope") })
		local nobody = newStore({ me = false })
		assert.are.same({ nil, "identity" }, { nobody:joinBoard("CORK1:x") })
	end)

	it("lets only the owner rotate the secret, and keeps the old ones", function()
		local store, board, changes = owned()
		local first = board.secret
		assert(store:rotateSecret(board.id))
		assert.are_not.equal(first, board.secret)
		assert.are.equal(24, #board.secret)
		assert.are.same({ first }, board.oldSecrets)
		assert.are.equal("board", changes[#changes].kind)
		for _ = 1, 6 do
			store:rotateSecret(board.id)
		end
		assert.are.equal(5, #board.oldSecrets)
		Store.retire(board, board.oldSecrets[3])
		assert.are.equal(5, #board.oldSecrets)
		local other = newStore({ me = "Bob-Realm", prefix = "b0b0b0b0" })
		local joined = other:joinBoard(Invite.encode(board))
		assert.are.same({ nil, "not_owner" }, { other:rotateSecret(joined.id) })
		assert.are.same({ nil, "missing" }, { store:rotateSecret("nope") })
	end)

	it("removes a member and rotates the secret", function()
		local store, board, changes = owned()
		Merge.applyMember(board, { name = "Bob-Realm", role = "member", rev = T0, editor = "Bob-Realm", removed = false })
		local secret = board.secret
		local record = assert(store:removeMember(board.id, "Bob-Realm"))
		assert.is_true(record.removed)
		assert.are_not.equal(secret, board.secret)
		assert.are.same({ "board", "member", "board" }, kinds(changes))
		assert.are.same({ nil, "not_member" }, { store:removeMember(board.id, "Bob-Realm") })
		assert.are.same({ nil, "not_member" }, { store:removeMember(board.id, "Nobody-Realm") })
		assert.are.same({ nil, "remove_self" }, { store:removeMember(board.id, ME) })
		assert.are.same({ nil, "missing" }, { store:removeMember("nope", "Bob-Realm") })
		local other = newStore({ me = "Bob-Realm", prefix = "b0b0b0b0" })
		local joined = other:joinBoard(Invite.encode(board))
		assert.are.same({ nil, "not_owner" }, { other:removeMember(joined.id, ME) })
		assert.are.same({ nil, "identity" }, { newStore({ me = false }):removeMember(board.id, "Bob-Realm") })
	end)

	it("lists members, owners first, without removed ones", function()
		local store, board = owned()
		for _, name in ipairs({ "Zed-Realm", "Amy-Realm", "Gone-Realm" }) do
			Merge.applyMember(board, { name = name, role = "member", rev = T0, editor = ME, removed = name == "Gone-Realm" })
		end
		local names = {}
		for i, m in ipairs(Store.members(board)) do
			names[i] = m.name
		end
		assert.are.same({ ME, "Amy-Realm", "Zed-Realm" }, names)
		assert.are.same({}, Store.members({}))
		assert.is_true(store:isOwner(board))
	end)

	it("sets the cloud and guild options", function()
		local store, board, changes = owned()
		assert(store:setOption(board.id, "cloud", false))
		assert.is_false(board.cloud)
		assert(store:setOption(board.id, "guild", 1))
		assert.is_true(board.guild)
		assert.are.equal("board", changes[#changes].kind)
		assert.are.same({ nil, "option" }, { store:setOption(board.id, "secret", "x") })
		assert.are.same({ nil, "missing" }, { store:setOption("nope", "cloud", true) })
	end)

	it("records when members were last seen, locally", function()
		local board = {}
		Store.markSeen(board, "Bob-Realm", "MAGE", 5)
		Store.markSeen(board, "Bob-Realm", "not a class", 9)
		assert.are.same({ at = 9, class = "MAGE" }, board.seen["Bob-Realm"])
	end)

	it("applies records from peers and reports what it stored", function()
		local store, board, changes = owned()
		local n = note("a1b2c3d4-0009", { rev = T0 + 5 })
		local result = store:applyRemote(board.id, {
			notes = { n, note("bad"), n },
			members = { { name = "Bob-Realm", role = "member", rev = T0 + 1, editor = "Bob-Realm", removed = false },
				{ name = "x" } },
			meta = { name = "Renamed", rev = T0 + 9, editor = "Bob-Realm" },
		})
		assert.are.same({ "a1b2c3d4-0009" }, result.notes)
		assert.are.same({ "Bob-Realm" }, result.members)
		assert.is_true(result.meta)
		assert.are.same({ "id", "name" }, result.dropped)
		assert.are.same({ "board", "note*", "member*", "meta*" }, kinds(changes))
		assert.are.equal("Renamed", Store.name(board))
		result = store:applyRemote(board.id, { meta = { name = "Old", rev = 1, editor = "Bob-Realm" } })
		assert.is_false(result.meta)
		assert.are.same({}, result.dropped)
		result = store:applyRemote(board.id, { meta = { name = "" } })
		assert.are.same({ "name" }, result.dropped)
		assert.are.same({ nil, "missing" }, { store:applyRemote("nope", {}) })
	end)
end)
