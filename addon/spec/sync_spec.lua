-- The sync engine over simulated members (helpers/sim.lua): the Phase 2, 3
-- and 4 acceptance criteria in docs/design.md §12, as far as they can be
-- checked outside the game.

local Sim = require("helpers.sim")
local Invite = require("Core.Invite")
local Digest = require("Core.Digest")
local Merge = require("Core.Merge")
local Sync = require("Core.Sync")

-- A board owned by the first node and joined by the rest, all converged.
local function group(names, opts)
	local sim = Sim.new(opts)
	local nodes = {}
	for i, name in ipairs(names) do
		nodes[i] = sim:add(name)
	end
	local board = assert(nodes[1].store:createBoard("Molten Core prep"))
	for i = 2, #nodes do
		assert(nodes[i].store:joinBoard(Invite.encode(board)))
	end
	assert(sim:runUntil(function()
		return Sim.converged(nodes, board.id)
	end, 30), "the group didn't converge")
	return sim, nodes, board.id
end

local function count(list, pred)
	local n = 0
	for _, x in ipairs(list) do
		if pred(x) then
			n = n + 1
		end
	end
	return n
end

describe("Sync: live P2P (Phase 2)", function()
	it("a joiner gets the board name, the member list and the notes", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local a, b = nodes[1], nodes[2]
		for i = 1, 3 do
			a.store:addNote(id, "note " .. i)
		end
		sim:run(10)
		local c = sim:add("Cara")
		c.store:joinBoard(Invite.encode(Sim.board(a, id)))
		assert.is_truthy(sim:runUntil(function()
			return Sim.converged({ a, b, c }, id)
		end, 30))
		local board = Sim.board(c, id)
		assert.are.equal("Molten Core prep", board.meta.name)
		assert.is_truthy(board.sync.lastPeer, "the catch-up should count as synced with someone")
		assert.are.equal(3, #require("Core.Store").notes(board))
		assert.are.equal(3, #require("Core.Store").members(board))
		assert.are.equal("owner", board.members["Will-Realm"].role)
	end)

	it("an edit appears on the other client within 5 s", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local a, b = nodes[1], nodes[2]
		local note = a.store:addNote(id, "Need 4x fire resistance")
		local took = sim:runUntil(function()
			return Sim.board(b, id).notes[note.id] ~= nil
		end, 5, 0.1)
		assert.is_truthy(took)
		b.store:editNote(id, note.id, { text = "Need 6x", color = 3 })
		took = sim:runUntil(function()
			return Sim.board(a, id).notes[note.id].text == "Need 6x"
		end, 5, 0.1)
		assert.is_truthy(took)
		b.store:deleteNote(id, note.id)
		assert.is_truthy(sim:runUntil(function()
			return Sim.board(a, id).notes[note.id].deleted
		end, 5, 0.1))
		assert.is_true(sim:sent("PUT")[1].prio == "ALERT")
	end)

	it("renames sync as board meta", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		nodes[2].store:renameBoard(id, "BWL prep")
		assert.is_truthy(sim:runUntil(function()
			return Sim.board(nodes[1], id).meta.name == "BWL prep"
		end, 5, 0.1))
	end)

	it("coalesces repeated edits to one note while they wait", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local a, b = nodes[1], nodes[2]
		local note = a.store:addNote(id, "v0")
		sim:run(5)
		a.locked = true
		for i = 1, 10 do
			a.store:editNote(id, note.id, { text = "v" .. i })
		end
		local start = sim.time
		sim:run(5)
		a.locked = false
		assert.is_truthy(sim:runUntil(function()
			return Sim.board(b, id).notes[note.id].text == "v10"
		end, 10, 0.1))
		assert.are.equal(1, #sim:sent("PUT", start))
	end)

	it("ignores traffic for boards it doesn't hold, from removed members, and from itself", function()
		local _, nodes, id = group({ "Will", "Bob" })
		local a = nodes[1]
		local sync = a.sync
		local before = sync.stats.ignored
		assert.is_false(sync:receive({ v = 1, t = "PUT", b = "zzzzzzzzzzzzzzzz", n = {} }, "Bob-Realm"))
		assert.is_false(sync:receive({ v = 1, t = "PUT", b = id, n = {} }, "Will-Realm"))
		assert(a.store:removeMember(id, "Bob-Realm"))
		assert.is_false(sync:receive({ v = 1, t = "PUT", b = id, n = {} }, "Bob-Realm"))
		assert.are.equal(before + 3, sync.stats.ignored)
	end)

	it("records the level each member was last seen at, from their HELLO", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local a, b = nodes[1], nodes[2]
		assert.are.equal(20, Sim.board(a, id).seen["Bob-Realm"].level)
		b.sync.env.level = 21
		b.sync:hello(id)
		assert(sim:runUntil(function()
			return Sim.board(a, id).seen["Bob-Realm"].level == 21
		end, 10), "the new level never arrived")
		-- A HELLO without a usable level keeps the one already seen.
		local hello = b.sync:buildHello({ board = id })
		hello.lvl = "sixty"
		assert.is_true(a.sync:receive(hello, "Bob-Realm"))
		assert.are.equal(21, Sim.board(a, id).seen["Bob-Realm"].level)
	end)

	it("drops malformed envelopes without errors", function()
		local _, nodes, id = group({ "Will", "Bob" })
		local sync = nodes[1].sync
		local bad = {
			{ t = "HELLO" },
			{ t = "HELLO", r = 1, d = 1, n = 1, c = 1, md = 1, k = {}, kc = {} },
			{ t = "HELLO", r = 1, d = -1, n = 1, c = 1, md = 1 },
			{ t = "IDX", to = 5 },
			{ t = "IDX", to = "Will-Realm", e = { { "bad id", 1, "Bob-Realm" } } },
			{ t = "IDX", to = "Will-Realm", e = {}, bk = { 99 } },
			{ t = "IDX", to = "Will-Realm", e = { 5 } },
			{ t = "NEED", to = "Will-Realm", ids = { {} } },
			{ t = "NEED" },
			{ t = "PUT", n = "x" },
			{ t = "PUT", n = { 1, 2, 3 } },
			{ t = "MEMBERS", m = 5 },
			{ t = "META", m = "x" },
		}
		local big = {}
		for i = 1, Sync.MAX_LIST + 1 do
			big[i] = "a1b2c3d4-0001"
		end
		bad[#bad + 1] = { t = "NEED", to = "Will-Realm", ids = big }
		local before = sync.stats.malformed
		for _, e in ipairs(bad) do
			e.v, e.b = 1, id
			sync:receive(e, "Bob-Realm")
		end
		-- PUT with junk notes is handled (the sanitiser drops them); the rest are malformed.
		assert.are.equal(before + #bad - 1, sync.stats.malformed)
		assert.are.equal(0, #require("Core.Store").notes(Sim.board(nodes[1], id)))
	end)
end)

describe("Sync: anti-entropy (Phase 3)", function()
	it("catches up an offline member within 60 s, exchanging only mismatched buckets", function()
		local sim, nodes, id = group({ "Will", "Bob" }, { seed = 11 })
		local a, b = nodes[1], nodes[2]
		for i = 1, 30 do
			a.store:addNote(id, "old " .. i)
		end
		assert(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, 60))
		sim:logout(a)
		local ids = {}
		for i = 1, 20 do
			ids[i] = b.store:addNote(id, "new " .. i).id
			sim:run(0.5)
		end
		for i = 1, 5 do
			b.store:editNote(id, ids[i], { text = "edited " .. i })
		end
		for i = 6, 8 do
			b.store:deleteNote(id, ids[i])
		end
		sim:run(30)
		local mismatched = Digest.mismatched(a.sync:summary(Sim.board(a, id)).buckets,
			b.sync:summary(Sim.board(b, id)).buckets)
		local start = sim.time
		sim:login(a)
		assert.is_truthy(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, 60))
		local covered = {}
		for _, m in ipairs(sim:sent("IDX", start)) do
			assert.are.equal("Will-Realm", m.to)
			for _, bucket in ipairs(m.envelope.bk) do
				covered[#covered + 1] = bucket
			end
		end
		table.sort(covered)
		assert.are.same(mismatched, covered)
		assert.is_true(#mismatched < Digest.BUCKETS)
	end)

	it("never brings a deleted note back, even from a stale third client", function()
		local sim, nodes, id = group({ "Will", "Bob", "Cara" }, { seed = 5 })
		local a, b, c = nodes[1], nodes[2], nodes[3]
		local keep = a.store:addNote(id, "keep")
		local doomed = a.store:addNote(id, "doomed")
		assert(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, 30))
		sim:logout(c)
		b.store:deleteNote(id, doomed.id)
		sim:run(10)
		sim:logout(a)
		sim:logout(b)
		-- C comes back holding the live note; nobody who saw the delete is online yet.
		sim:login(c)
		sim:run(20)
		sim:login(a)
		sim:login(b)
		assert.is_truthy(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, 60))
		for _, node in ipairs(nodes) do
			assert.is_true(Sim.board(node, id).notes[doomed.id].deleted)
			assert.is_false(Sim.board(node, id).notes[keep.id].deleted)
		end
	end)

	it("converges concurrent edits to one note on the same winner on 3 clients", function()
		local sim, nodes, id = group({ "Will", "Bob", "Cara" }, { seed = 9 })
		local note = nodes[1].store:addNote(id, "start")
		assert(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, 30))
		-- Each edits while the others are away, at the same server second.
		for i, node in ipairs(nodes) do
			for j, other in ipairs(nodes) do
				if j ~= i then
					sim:logout(other)
				end
			end
			if not node.online then
				sim:login(node)
			end
			node.store:editNote(id, note.id, { text = "from " .. node.name })
			sim:logout(node)
		end
		for _, node in ipairs(nodes) do
			sim:login(node)
		end
		assert.is_truthy(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, 60))
		local winner = Sim.board(nodes[1], id).notes[note.id]
		for _, node in ipairs(nodes) do
			local n = Sim.board(node, id).notes[note.id]
			assert.are.equal(winner.text, n.text)
			assert.are.equal(0, Merge.compareNote(winner, n))
		end
	end)

	it("with 5 members online, a HELLO gets exactly one IDX in at least 90% of trials #slow", function()
		local trials, single = 30, 0
		for seed = 1, trials do
			local sim, nodes, id = group({ "Will", "Bob", "Cara", "Dorn", "Eve" }, { seed = seed * 7 })
			local a = nodes[1]
			sim:logout(a)
			nodes[2].store:addNote(id, "while you were out")
			sim:run(5)
			local start = sim.time
			sim:login(a)
			sim:run(15)
			local idx = count(sim:sent("IDX", start), function(m)
				return m.to == "Will-Realm"
			end)
			if idx == 1 then
				single = single + 1
			end
			assert.is_true(Sim.converged(nodes, id))
		end
		assert.is_true(single / trials >= 0.9, ("single IDX in %d of %d trials"):format(single, trials))
	end)

	it("sends periodic HELLOs, skipping one right after another member's #slow", function()
		local sim, nodes, id = group({ "Will", "Bob" }, { seed = 3 })
		local start = sim.time
		sim:run(Sync.HELLO_EVERY * 4)
		local hellos = sim:sent("HELLO", start)
		assert.is_true(#hellos >= 4)
		for _, node in ipairs(nodes) do
			local own = count(hellos, function(m)
				return m.from == node.name
			end)
			assert.is_true(own >= 1, node.name .. " never said HELLO")
		end
		assert.is_true(Sim.converged(nodes, id))
	end)

	it("reports online members and the last peer synced with", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		sim:run(Sync.HELLO_EVERY + Sync.HELLO_JITTER + 5)
		local status = nodes[1].sync:status(id)
		assert.are.same({ "Bob-Realm" }, status.online)
		assert.are.equal("Bob-Realm", status.lastPeer)
		assert.are.equal(0, status.queued)
		assert.is_false(status.paused)
		assert.is_nil(nodes[1].sync:status("nope"))
		sim:logout(nodes[2])
		sim:run(Sync.PRESENCE + 1)
		assert.are.same({}, nodes[1].sync:status(id).online)
	end)
end)

describe("Sync: hardening (Phase 4)", function()
	it("queues edits while restricted and delivers them within 10 s of the gate opening", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local a, b = nodes[1], nodes[2]
		a.locked = true
		local notes = {}
		for i = 1, 3 do
			notes[i] = a.store:addNote(id, "during the pull " .. i)
		end
		sim:run(30)
		assert.is_nil(Sim.board(b, id).notes[notes[1].id])
		assert.is_true(a.sync:status(id).paused)
		assert.is_true(a.sync:status(id).queued >= 1)
		a.locked = false
		local took = sim:runUntil(function()
			for _, n in ipairs(notes) do
				if not Sim.board(b, id).notes[n.id] then
					return false
				end
			end
			return true
		end, 10, 0.1)
		assert.is_truthy(took)
		assert.are.equal("encounter", a.outbox.lastClosed.reason)
	end)

	it("catches up a large board in game, at BULK, when the joiner has no companion #slow", function()
		local sim, nodes, id = group({ "Will" }, { seed = 2 })
		local a = nodes[1]
		for i = 1, 80 do
			a.store:addNote(id, ("A fairly long note number %d with some words to take up space."):format(i))
		end
		sim:run(5)
		local b = sim:add("Bob")
		b.store:joinBoard(Invite.encode(Sim.board(a, id)))
		local start = sim.time
		assert.is_truthy(sim:runUntil(function()
			return Sim.converged({ a, b }, id)
		end, 600, 2))
		assert.is_true(count(sim:sent(nil, start), function(m)
			return m.prio == "BULK"
		end) > 0)
		assert.is_nil(b.sync:status(id).behind)
	end)

	it("pulls only the newest notes in game when the cloud can bring the rest", function()
		local sim, nodes, id = group({ "Will" }, { seed = 4 })
		local a = nodes[1]
		for i = 1, 80 do
			a.store:addNote(id, "note " .. i)
			sim:run(1)
		end
		local b = sim:add("Bob")
		sim:logout(b)
		local board = b.store:joinBoard(Invite.encode(Sim.board(a, id)))
		board.sync.lastCloudAt = sim:serverTime() -- the companion has synced this board
		local start = sim.time
		sim:login(b)
		sim:run(120)
		local idx = sim:sent("IDX", start)
		assert.is_true(#idx >= 1)
		assert.are.equal(1, idx[1].envelope.p)
		assert.are.equal(Sync.PARTIAL, #idx[1].envelope.e)
		local have = #require("Core.Store").notes(board)
		assert.is_true(have >= Sync.PARTIAL and have < 80, "has " .. have)
		assert.is_true(b.sync:status(id).behind >= 60)
		-- The newest ones are the ones pulled.
		local newest = require("Core.Store").notes(Sim.board(a, id))
		assert.is_truthy(board.notes[newest[#newest].id])
	end)

	it("converges with 20% message loss, given time #slow", function()
		local sim, nodes, id = group({ "Will", "Bob", "Cara" }, { seed = 13 })
		sim.loss = 0.2
		for i = 1, 15 do
			nodes[1 + i % 3].store:addNote(id, "lossy " .. i)
			sim:run(2)
		end
		sim.loss = 0
		assert.is_truthy(sim:runUntil(function()
			return Sim.converged(nodes, id)
		end, Sync.HELLO_EVERY * 3, 5))
	end)
end)

describe("Sync internals", function()
	it("keeps the digest cache in step with the notes", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local a = nodes[1]
		local board = Sim.board(a, id)
		for i = 1, 40 do
			a.store:addNote(id, "n" .. i)
		end
		sim:run(10)
		local cached = a.sync:summary(board)
		local fresh = Digest.compute(board.notes)
		assert.are.equal(fresh.digest, cached.digest)
		assert.are.same(fresh.buckets, cached.buckets)
		assert.are.equal(fresh.count, cached.count)
		a.sync:invalidate(id)
		assert.are.equal(fresh.digest, a.sync:summary(board).digest)
	end)

	it("ranks responders the same way on every member", function()
		local sim, nodes, id = group({ "Will", "Bob", "Cara", "Dorn" })
		sim:run(Sync.HELLO_EVERY + Sync.HELLO_JITTER + 5)
		local ranks = {}
		for _, node in ipairs(nodes) do
			if node.name ~= "Will-Realm" then
				ranks[#ranks + 1] = node.sync:rank(id, "Will-Realm", 12345)
			end
		end
		table.sort(ranks)
		assert.are.same({ 0, 1, 2 }, ranks)
	end)

	it("forgets a board deleted from this account", function()
		local sim, nodes, id = group({ "Will", "Bob" })
		local b = nodes[2]
		b.store:deleteBoard(id)
		sim:run(5)
		assert.is_nil(b.sync.peers[id])
		assert.is_nil(b.sync.helloTimers[id])
		assert.are.equal(0, b.outbox:depth(id))
		-- Its traffic is now ignored.
		nodes[1].store:addNote(id, "anyone?")
		sim:run(5)
		assert.is_nil(Sim.board(b, id))
	end)

	it("a removed member no longer hears the board after the secret rotates", function()
		local sim, nodes, id = group({ "Will", "Bob", "Cara" })
		local a, b, c = nodes[1], nodes[2], nodes[3]
		assert(a.store:removeMember(id, "Bob-Realm"))
		c.store:joinBoard(Invite.encode(Sim.board(a, id))) -- Cara gets the new invite
		sim:run(10)
		local note = a.store:addNote(id, "secret plans")
		sim:run(10)
		assert.is_truthy(Sim.board(c, id).notes[note.id])
		assert.is_nil(Sim.board(b, id).notes[note.id])
		assert.is_true(Sim.board(c, id).members["Bob-Realm"].removed)
	end)
end)
