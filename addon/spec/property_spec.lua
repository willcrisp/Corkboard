-- Property tests for the merge core (docs/design.md §11). Seeded and
-- deterministic: a failure message names the seed that reproduces it.

local Merge = require("Core.Merge")
local Digest = require("Core.Digest")

local T0 = 1790000000

-- Park-Miller minimal standard generator: the same sequence on every platform.
local function prng(seed)
	local state = seed % 2147483646 + 1
	return function(n)
		state = state * 16807 % 2147483647
		return state % n + 1
	end
end

local function pick(rand, list)
	return list[rand(#list)]
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function shuffled(rand, list)
	local out = copy(list)
	for i = #out, 2, -1 do
		local j = rand(i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- Merge laws on random records --------------------------------------------------
-- Small domains, so exact (rev, editor) ties with different content are common.

local IDS = { "aaaaaaaa-1", "aaaaaaaa-2", "bbbbbbbb-1" }
local NAMES = { "Amy-Realm", "Bob-Realm", "bob-Realm", "Øystein-Realm" }
local TEXTS = { "a", "b", "|cffff0000c|r", "" }

local function randomNote(rand)
	local deleted = rand(4) == 1
	local note = {
		id = pick(rand, IDS),
		author = pick(rand, NAMES),
		created = T0 + rand(2),
		rev = T0 + rand(4),
		editor = pick(rand, NAMES),
		text = deleted and "" or pick(rand, TEXTS),
		color = rand(2),
		deleted = deleted,
	}
	if rand(20) == 1 then
		note.rev = 0 -- invalid: must be dropped without disturbing anything
	end
	return note
end

local function isValid(note)
	return note.rev ~= 0
end

local function applyAll(records)
	local board = { clock = T0, notes = {} }
	for _, record in ipairs(records) do
		Merge.applyNote(board, record)
	end
	return board
end

-- The expected board: for each id, the maximum valid record.
local function model(records)
	local board = { clock = T0, notes = {} }
	for _, record in ipairs(records) do
		if isValid(record) then
			local current = board.notes[record.id]
			if not current or Merge.compareNote(record, current) > 0 then
				board.notes[record.id] = record
			end
			board.clock = math.max(board.clock, record.rev)
		end
	end
	return board
end

-- luassert is slow per call; hot loops only reach it on failure.
local function check(ok, message)
	if not ok then
		assert.is_true(ok, message)
	end
end

local function sign(n)
	return n < 0 and -1 or (n > 0 and 1 or 0)
end

describe("merge laws (random records)", function()
	it("compareNote is a total order that only ties on identical records", function()
		local rand = prng(1)
		for _ = 1, 5000 do
			local a, b, c = randomNote(rand), randomNote(rand), randomNote(rand)
			b.id, c.id = a.id, a.id -- versions of one note
			a.rev, b.rev, c.rev = T0 + rand(2), T0 + rand(2), T0 + rand(2)
			local ab, ba = Merge.compareNote(a, b), Merge.compareNote(b, a)
			check(-sign(ab) == sign(ba), "antisymmetric")
			check(Merge.compareNote(a, a) == 0, "reflexive")
			if ab == 0 then
				assert.are.same(a, b)
			end
			if ab <= 0 and Merge.compareNote(b, c) <= 0 then
				check(Merge.compareNote(a, c) <= 0, "transitive")
			end
		end
	end)

	it("any order, with duplicates, gives the model's board", function()
		for seed = 1, 1000 do
			local rand = prng(seed)
			local records = {}
			for i = 1, rand(8) do
				records[i] = randomNote(rand)
			end
			local expected = model(records)
			local forward = applyAll(records)
			assert.are.same(expected, forward, "seed " .. seed)

			local noisy = shuffled(rand, records)
			for i = 1, rand(4) do -- duplicate a few deliveries
				table.insert(noisy, rand(#noisy + 1), records[rand(#records)])
				noisy[#noisy + 1] = records[i] or records[1]
			end
			assert.are.same(expected, applyAll(noisy), "seed " .. seed)
		end
	end)

	it("merging two boards is commutative, associative and idempotent", function()
		for seed = 1, 500 do
			local rand = prng(seed)
			local function randomBoard()
				local records = {}
				for i = 1, rand(5) do
					records[i] = randomNote(rand)
				end
				return applyAll(records)
			end
			local function merged(...)
				local board = { clock = T0 }
				for _, source in ipairs({ ... }) do
					Merge.applyNotes(board, source.notes or {})
				end
				return board
			end
			local x, y, z = randomBoard(), randomBoard(), randomBoard()
			assert.are.same(merged(x, y), merged(y, x), "seed " .. seed)
			assert.are.same(merged(merged(x, y), z), merged(x, merged(y, z)), "seed " .. seed)
			assert.are.same(merged(x), merged(x, x), "seed " .. seed)
		end
	end)
end)

-- Digest lines ------------------------------------------------------------------
-- Between two edits by one editor, a note's digest line changes only in its rev
-- digits. Adler-32 missed some of those changes (revs 81 apart); the digest
-- hash must see every one that touches up to three adjacent digits.

describe("digest line hash", function()
	it("changes whenever up to three adjacent rev digits change", function()
		local Util = require("Core.Util")
		local rand = prng(3)
		for _ = 1, 12 do
			local rev = T0 + rand(10000000)
			local digits = Util.formatInt(rev)
			local base = Util.fnv1a32(Digest.line({ id = "22222222-4", rev = rev, editor = "Zed-Realm" }))
			for pos = 1, #digits - 2 do
				for k = 0, 999 do
					local changed = digits:sub(1, pos - 1) .. ("%03d"):format(k) .. digits:sub(pos + 3)
					if changed ~= digits and changed:sub(1, 1) ~= "0" then
						local line = Digest.line({ id = "22222222-4", rev = tonumber(changed), editor = "Zed-Realm" })
						check(Util.fnv1a32(line) ~= base, "collision at rev " .. changed .. " vs " .. digits)
					end
				end
			end
		end
	end)
end)

-- Simulated network -----------------------------------------------------------------
-- Nodes make random local changes and broadcast them as PUTs. The network drops,
-- duplicates and reorders deliveries; nodes also sync through a server. After a
-- final catch-up, every replica must hold the same board, and for each note it
-- must be the greatest version anyone ever produced.

local function simulate(seed, options)
	local rand = prng(seed)
	local nodes = {}
	for i = 1, options.nodes do
		nodes[i] = {
			board = { clock = 0 },
			editor = options.editors[i],
			prefix = ("%08x"):format(i * 286331153), -- 0x11111111
			skew = options.skew[i] or 0,
			counter = 0,
			lastRev = 0,
			lastClock = 0,
		}
	end
	local server = { board = { clock = 0 } }
	local inflight = {}
	local produced = {}
	local now = T0
	local context = ("seed %d"):format(seed)

	local function send(from, record)
		for _, node in ipairs(nodes) do
			if node ~= from then
				local r = rand(10)
				if r > 1 then -- 10% dropped
					inflight[#inflight + 1] = { to = node, record = record }
				end
				if r == 10 then -- 10% duplicated
					inflight[#inflight + 1] = { to = node, record = record }
				end
			end
		end
		if rand(3) == 1 then
			Merge.applyNote(server.board, record)
		end
	end

	local function liveIds(board)
		local ids = {}
		for id, note in pairs(board.notes or {}) do
			if not note.deleted then
				ids[#ids + 1] = id
			end
		end
		table.sort(ids)
		return ids
	end

	local function localChange(node)
		local t = now + node.skew
		local ids = liveIds(node.board)
		local record
		if #ids == 0 or rand(4) == 1 then
			node.counter = node.counter + 1
			local fields = { id = node.prefix .. "-" .. node.counter, author = node.editor, text = "new " .. t }
			record = assert(Merge.createNote(node.board, fields, t))
		elseif rand(4) == 1 then
			record = assert(Merge.deleteNote(node.board, pick(rand, ids), node.editor, t))
		else
			local changes = { text = ("%s at %d"):format(node.prefix, t), color = rand(5) }
			record = assert(Merge.editNote(node.board, pick(rand, ids), changes, node.editor, t))
		end
		check(record.rev > node.lastRev, context .. ": local revs must increase")
		node.lastRev = record.rev
		produced[#produced + 1] = record
		send(node, record)
	end

	local function syncWithServer(node)
		Merge.applyNotes(server.board, node.board.notes or {})
		Merge.applyNotes(node.board, server.board.notes or {})
	end

	-- HELLO -> IDX for mismatched buckets -> both sides send what differs.
	local function antiEntropy(a, b)
		local mismatched = {}
		local da, db = Digest.compute(a.notes or {}), Digest.compute(b.notes or {})
		for _, bucket in ipairs(Digest.mismatched(da.buckets, db.buckets)) do
			mismatched[bucket] = true
		end
		local function push(from, to)
			local batch = {}
			for id, note in pairs(from.notes or {}) do
				if mismatched[Digest.bucket(id)] then
					batch[#batch + 1] = note
				end
			end
			Merge.applyNotes(to, batch)
		end
		push(a, b)
		push(b, a)
	end

	for _ = 1, options.steps do
		now = now + rand(3) - 1 -- often several changes in the same second
		local r = rand(100)
		if r <= 40 then
			localChange(pick(rand, nodes))
		elseif r <= 85 and #inflight > 0 then
			local message = table.remove(inflight, rand(#inflight))
			Merge.applyNote(message.to.board, message.record)
		elseif r <= 93 then
			syncWithServer(pick(rand, nodes))
		else
			antiEntropy(pick(rand, nodes).board, pick(rand, nodes).board)
		end
		for _, node in ipairs(nodes) do
			local clock = node.board.clock
			check(clock >= node.lastClock, context .. ": clock went backwards")
			node.lastClock = clock
			for _, note in pairs(node.board.notes or {}) do
				check(note.rev <= clock, context .. ": note rev above clock")
			end
		end
	end

	-- Catch-up: deliver what's still in flight, then reconcile.
	for _, message in ipairs(inflight) do
		Merge.applyNote(message.to.board, message.record)
	end
	local replicas = { server.board }
	for _, node in ipairs(nodes) do
		replicas[#replicas + 1] = node.board
	end
	for _ = 1, 2 do
		for i = 1, #replicas do
			for j = i + 1, #replicas do
				options.reconcile(antiEntropy, replicas[i], replicas[j])
			end
		end
	end

	local expected = {}
	for _, record in ipairs(produced) do
		local current = expected[record.id]
		if not current or Merge.compareNote(record, current) > 0 then
			expected[record.id] = record
		end
	end
	local digest = Digest.compute(expected).digest
	for i, board in ipairs(replicas) do
		assert.are.same(expected, board.notes or {}, ("%s: replica %d"):format(context, i))
		assert.are.equal(digest, Digest.compute(board.notes or {}).digest, context)
	end
	return #produced
end

describe("convergence (simulated nodes)", function()
	it("3-5 members with skewed clocks converge through bucketed anti-entropy", function()
		local total = 0
		for seed = 1, 150 do
			local count = 3 + seed % 3
			total = total + simulate(seed, {
				nodes = count,
				editors = { "Amy-Realm", "Bob-Realm", "Zed-Realm", "bob-Realm", "Øystein-Realm" },
				skew = { 0, -5, 7, 2, -1 },
				steps = 300,
				reconcile = function(antiEntropy, a, b)
					antiEntropy(a, b)
				end,
			})
		end
		assert.is_true(total > 10000) -- the runs made plenty of changes
	end)

	it("one character on two installs converges through full exchange", function()
		-- Nodes 1 and 2 are the same character, so both can produce the same
		-- (rev, editor) with different content. The digest can't see that tie;
		-- exchanging whole boards still converges on one winner.
		for seed = 1, 150 do
			simulate(seed, {
				nodes = 4,
				editors = { "Will-Realm", "Will-Realm", "Amy-Realm", "Bob-Realm" },
				skew = { 0, 0, 3, -3 },
				steps = 300,
				reconcile = function(_, a, b)
					Merge.applyNotes(b, copy(a.notes or {}))
					Merge.applyNotes(a, copy(b.notes or {}))
				end,
			})
		end
	end)
end)
