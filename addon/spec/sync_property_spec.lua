-- Property test for the whole sync protocol (docs/design.md §11): random
-- edits, deletes, renames, joins, logouts, lockdowns and lost messages across
-- 3-5 simulated members must converge once everyone is back online. Seeded
-- and deterministic: a failure names the seed. Left out of the coverage run,
-- like property_spec, because it's slow under the coverage hook.

local Sim = require("helpers.sim")
local Invite = require("Core.Invite")
local Store = require("Core.Store")
local Sync = require("Core.Sync")

local NAMES = { "Will", "Bob", "Cara", "Dorn", "Eve" }

local function scenario(seed)
	local sim = Sim.new({ seed = seed, loss = (seed % 3) * 0.1 })
	local r = sim.random
	local function pick(list)
		return list[math.floor(r() * #list) + 1]
	end
	local nodes = { sim:add(NAMES[1]) }
	local id = nodes[1].store:createBoard("Board " .. seed).id
	local invite = Invite.encode(Sim.board(nodes[1], id))
	local size = 3 + seed % 3
	for i = 2, size do
		nodes[i] = sim:add(NAMES[i])
		if r() < 0.7 then
			nodes[i].store:joinBoard(invite)
		end
	end
	for _ = 1, 60 do
		local node = pick(nodes)
		local board = Sim.board(node, id)
		local roll = r()
		if not board then
			if roll < 0.3 then
				node.store:joinBoard(invite)
			end
		elseif roll < 0.35 then
			node.store:addNote(id, "note " .. math.floor(r() * 1000))
		elseif roll < 0.55 then
			local live = Store.notes(board)
			if #live > 0 then
				local changes = { text = "edit " .. math.floor(r() * 1000), color = 1 + math.floor(r() * 5) }
				node.store:editNote(id, pick(live).id, changes)
			end
		elseif roll < 0.62 then
			local live = Store.notes(board)
			if #live > 0 then
				node.store:deleteNote(id, pick(live).id)
			end
		elseif roll < 0.66 then
			node.store:renameBoard(id, "Name " .. math.floor(r() * 100))
		elseif roll < 0.8 then
			if node.online then
				sim:logout(node)
			else
				sim:login(node)
			end
		elseif roll < 0.86 then
			node.locked = not node.locked
		end
		sim:run(r() * 20)
	end
	-- Heal: everyone online, unlocked, no loss.
	sim.loss = 0
	local members = {}
	for _, node in ipairs(nodes) do
		node.locked = false
		if not node.online then
			sim:login(node)
		end
		if not Sim.board(node, id) then
			node.store:joinBoard(invite)
		end
		members[#members + 1] = node
	end
	local took = sim:runUntil(function()
		return Sim.converged(members, id)
	end, Sync.HELLO_EVERY * 3, 5)
	return took, nodes, id
end

describe("sync protocol convergence (property)", function()
	for seed = 1, 25 do
		it("converges after random churn, seed " .. seed, function()
			local took, nodes, id = scenario(seed)
			assert.is_truthy(took, "seed " .. seed .. " did not converge")
			for _, node in ipairs(nodes) do
				assert.are.equal(0, node.sync.stats.malformed, node.name .. ": " .. tostring(node.sync.stats.lastError))
			end
			-- Tombstones stay tombstones everywhere.
			local reference = Sim.board(nodes[1], id)
			for noteId, note in pairs(reference.notes) do
				for _, node in ipairs(nodes) do
					assert.are.equal(note.deleted, Sim.board(node, id).notes[noteId].deleted)
				end
			end
		end)
	end
end)
