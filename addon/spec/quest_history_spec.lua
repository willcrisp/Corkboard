-- Completed quests and chains (docs/design.md §9.3 "Completed" and
-- "Chains"): each member's last turn-ins ride on the second line of their
-- quest-log note, a quest accepted right after a turn-in from the same NPC
-- is learned as that chain's next part, and the Quests tab shows both.

local Store = require("Core.Store")
local View = require("Core.View")
local Commands = require("Core.Commands")
local Sanitise = require("Core.Sanitise")
local Client = require("helpers.client")

local T0 = 1790000000
local ME = "Will-Realm"
local BOB = "Bob-Realm"
local PREFIX = "a1b2c3d4"
local TITLES = {
	[7] = "Kobold Camp Cleanup",
	[15] = "Investigate Echo Ridge",
	[46] = "Bounty on Murlocs",
	[54] = "Report to Goldshire",
	[166] = "The Defias Brotherhood",
}

local function newStore(options)
	options = options or {}
	local db = { global = { boards = {} }, char = {} }
	local t, seed = T0, 1
	local env = {
		now = function()
			t = t + 1
			return t
		end,
		rand = function(n)
			seed = seed * 16807 % 2147483647
			return seed % n + 1
		end,
		me = options.me or ME,
		prefix = options.prefix or PREFIX,
		questTitle = function(id)
			return TITLES[id]
		end,
		questDone = options.questDone,
	}
	return Store.new(db, env), db, env
end

local function quests(...)
	local list = {}
	for i = 1, select("#", ...), 2 do
		list[#list + 1] = { id = select(i, ...), level = select(i + 1, ...) }
	end
	return list
end

local function log(store, board, who)
	return Store.questLogs(store:board(board.id))[who or ME]
end

local function remoteLog(store, board, author, text, prefix)
	local now = T0 + 400
	assert.is_true(store:applyRemote(board.id, { notes = { {
		id = (prefix or "0badf00d") .. "-0", author = author, created = now, rev = now, editor = author, color = 1,
		deleted = false, kind = "quests", text = text,
	} } }).notes[1] ~= nil)
end

describe("the completed quests' format", function()
	it("writes turn-ins newest first as id.level.time, with the quest each follows, once each", function()
		local text = Store.encodeDone({
			{ id = 46, level = 10, at = T0 + 50, prev = 7 },
			{ id = 7, level = 5, at = T0 },
			{ id = 46, level = 10, at = T0 - 5 }, -- done before: only the newest counts
			{ id = 9, at = T0 - 9, prev = 9 }, -- no level, and a quest can't follow itself
		})
		assert.are.equal("46.10.1790000050.7,7.5.1790000000,9.0.1789999991", text)
		local entries = {
			{ id = 46, level = 10, at = T0 + 50, prev = 7 },
			{ id = 7, level = 5, at = T0 },
			{ id = 9, level = 0, at = T0 - 9 },
		}
		assert.are.same(entries, Store.decodeDone(text, true))
		assert.are.same(entries, Store.decodeDone("7:5,166:18\nD1;" .. text))
		assert.are.same(entries, Store.decodeDone("\nD1;" .. text))
		assert.are.same({}, Store.decodeDone("7:5,166:18"))
		assert.are.same({}, Store.decodeDone(nil))
	end)

	it("skips what isn't a turn-in, and keeps at most QUESTS_DONE_MAX", function()
		assert.are.same({ { id = 5, level = 5, at = 5 }, { id = 9, level = 3, at = 100 } },
			Store.decodeDone("x.1.2,0.5.1,5.5.5.5,9.3.100,9.3.50,12.1.2.3.4,13.1", true))
		local many = {}
		for i = 1, 40 do
			many[i] = { id = i, level = 1, at = T0 - i }
		end
		local text = Store.encodeDone(many)
		assert.are.equal(Store.QUESTS_DONE_MAX, #Store.decodeDone(text, true))
	end)

	it("marks the quest each quest in the log follows, which older readers skip", function()
		local text = Store.encodeQuests({ { id = 15, level = 3, prev = 7 }, { id = 7, level = 5, prev = 7 } })
		assert.are.equal("7:5,15:3/7", text)
		assert.are.same({ { id = 7, level = 5 }, { id = 15, level = 3, prev = 7 } }, Store.decodeQuests(text))
		-- The log is only the first line.
		local full = text .. "\nD1;46.10.1790000050.7,7.5.1790000000"
		assert.are.same(Store.decodeQuests(text), Store.decodeQuests(full))
		-- How a client from before this change reads a log: every id:level pair.
		local old = {}
		for id, level in full:gmatch("(%d+):(%d+)") do
			old[#old + 1] = id .. ":" .. level
		end
		assert.are.same({ "7:5", "15:3" }, old)
	end)
end)

describe("Store.follows", function()
	local last = { id = 7, at = 100, npc = "Creature-0-1-McBride" }

	it("links a quest taken soon after a turn-in, from the same NPC", function()
		assert.are.equal(7, Store.follows(last, 15, 130, "Creature-0-1-McBride"))
		assert.are.equal(7, Store.follows(last, 15, 100 + Store.FOLLOW_WINDOW, nil))
		assert.are.equal(7, Store.follows({ id = 7, at = 100 }, 15, 130, "Creature-0-1-Other"))
	end)

	it("doesn't link one from someone else, one taken later, or the same quest", function()
		assert.is_nil(Store.follows(last, 15, 130, "Creature-0-1-Other"))
		assert.is_nil(Store.follows(last, 15, 100 + Store.FOLLOW_WINDOW + 1, "Creature-0-1-McBride"))
		assert.is_nil(Store.follows(last, 7, 130, "Creature-0-1-McBride"))
		assert.is_nil(Store.follows(last, 15, 90, nil))
		assert.is_nil(Store.follows(nil, 15, 130, nil))
		assert.is_nil(Store.follows({ at = 100 }, 15, 130, nil))
	end)
end)

describe("Store: turn-ins and chains", function()
	it("shares turn-ins with the log, and the quest each was picked up after", function()
		local store, db = newStore()
		local board = store:createBoard("Raid")
		store:questLog(quests(7, 5))
		assert.is_true(store:questTurnedIn(7, 5, T0 + 10))
		assert.is_true(store:questAccepted(15, 7))
		assert.is_false(store:questAccepted(15, 7))
		assert.is_false(store:questAccepted(15, 15))
		assert.is_false(store:questAccepted(nil, 7))
		assert.are.same({ 1, true }, { store:questLog(quests(15, 3)) })
		assert.are.equal("15:3/7\nD1;7.5.1790000010", log(store, board).text)
		assert.are.equal(7, db.global.questLinks[15])

		store:questTurnedIn(15, 3, T0 + 20)
		store:questLog({})
		local text = log(store, board).text
		assert.are.equal("\nD1;15.3.1790000020.7,7.5.1790000010", text)
		assert.is_true(Sanitise.text(text))
		assert.are.same({}, Store.decodeQuests(text))
		assert.are.same({ 15, 7 }, { store:myDone()[1].id, store:myDone()[2].id })
		assert.is_false(store:questTurnedIn("x", 1, T0))
	end)

	it("sends one change for a turn-in and the quest leaving the log", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:questLog(quests(7, 5, 46, 10))
		local rev = log(store, board).rev
		store:questTurnedIn(7, 5, T0 + 10)
		assert.are.equal(rev, log(store, board).rev) -- waits for the read of the log
		assert.are.same({ 1, true }, { store:questLog(quests(46, 10)) })
		assert.are.same({ 0, false }, { store:questLog(quests(46, 10)) })
	end)

	it("moves a quest done again to the front, and keeps the newest", function()
		local store = newStore()
		for i = 1, Store.QUESTS_DONE_MAX + 5 do
			store:questTurnedIn(100 + i, 1, T0 + i)
		end
		store:questTurnedIn(110, 1, T0 + 100)
		local done = store:myDone()
		assert.are.equal(Store.QUESTS_DONE_MAX, #done)
		assert.are.same({ 110, 135, 134 }, { done[1].id, done[2].id, done[3].id })
	end)

	it("drops the oldest turn-ins when the whole wouldn't fit in a note", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		for i = 1, Store.QUESTS_DONE_MAX do
			store:questAccepted(900000000 + i, 800000000 + i)
			store:questTurnedIn(900000000 + i, 60, T0 + i)
		end
		local list = {}
		for i = 1, Store.QUESTS_MAX do
			list[i] = { id = 700000000 + i, level = 60 }
			store:questAccepted(700000000 + i, 600000000 + i)
		end
		store:questLog(list)
		local text = log(store, board).text
		assert.is_true(#text <= Sanitise.MAX_TEXT)
		assert.is_true(Sanitise.text(text))
		assert.are.equal(Store.QUESTS_MAX, #Store.decodeQuests(text))
		local kept = Store.decodeDone(text)
		assert.is_true(#kept > 0 and #kept < Store.QUESTS_DONE_MAX)
		assert.are.equal(900000000 + Store.QUESTS_DONE_MAX, kept[1].id) -- the newest stay
	end)

	it("gathers the board's links, the one most members hold winning and this account's first", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		remoteLog(store, board, BOB, "166:18/54\nD1;54.7.1790000300.15,15.3.1790000100.7")
		remoteLog(store, board, "Carol-Realm", "15:3/8,54:7/15", "0badf00e")
		remoteLog(store, board, "Dan-Realm", "15:3/7", "0badf00f")
		local links, levels = store:questLinks(board)
		assert.are.same({ [166] = 54, [54] = 15, [15] = 7 }, links)
		assert.are.same({ [166] = 18, [54] = 7, [15] = 3 }, levels)
		store:questAccepted(54, 46)
		assert.are.equal(46, (store:questLinks(board))[54])
	end)
end)

-- Bob is on 166, the fourth part of 7 -> 15 -> 54 -> 166, and has turned in
-- 54, 46, 15 and 7, newest first. Will is on 54, has turned in 7, and the
-- game says he hasn't done 15 or 46.
local function chainBoard()
	local store = newStore({
		questDone = function(id)
			return id == 7
		end,
	})
	local board = store:createBoard("Raid")
	store:questTurnedIn(7, 5, T0 + 10)
	store:questLog(quests(54, 7))
	remoteLog(store, board, BOB,
		"166:18/54\nD1;54.7.1790000300.15,46.10.1790000200,15.3.1790000100.7,7.5.1790000050")
	return store, board
end

describe("the Quests tab's chains", function()
	it("follows a chain back as far as it's known, and stops at a loop", function()
		assert.are.same({ 7, 15, 54 }, View.chainBefore({ [166] = 54, [54] = 15, [15] = 7 }, 166))
		assert.are.same({}, View.chainBefore({}, 166))
		assert.are.same({ 2, 1 }, View.chainBefore({ [3] = 1, [1] = 2, [2] = 1 }, 3))
		local long = {}
		for i = 2, 50 do
			long[i] = i - 1
		end
		assert.are.equal(View.CHAIN_MAX, #View.chainBefore(long, 50))
	end)

	it("marks a quest with earlier steps, and lists them with where you are when opened", function()
		local store, board = chainBoard()
		local out = View.questLog(store, board, BOB, {}, false, T0 + 400)
		assert.are.same({ log = 1, done = 4 }, out.counts)
		assert.are.equal("Only quests I'm on too", out.filterLabel)
		assert.are.equal(1, #out.rows)
		local row = out.rows[1]
		assert.are.same({ 166, 166, false, "Part 4", "" }, { row.id, row.key, row.open, row.part, row.when })

		out = View.questLog(store, board, BOB, {}, false, T0 + 400, "log", { [166] = true })
		assert.are.equal(5, #out.rows)
		assert.is_true(out.rows[1].open)
		assert.are.same({ nested = true, caption = true, index = 2,
			text = "Earlier in the chain · you've done 1 of 3" }, out.rows[2])
		local steps = { out.rows[3], out.rows[4], out.rows[5] }
		assert.are.same({ 7, 15, 54 }, { steps[1].id, steps[2].id, steps[3].id })
		assert.are.same({ "done", "no", "log" }, { steps[1].status, steps[2].status, steps[3].status })
		assert.are.same({ Commands.SHARED_ICON, Commands.MISSING_ICON, Commands.LOG_ICON },
			{ steps[1].mark, steps[2].mark, steps[3].mark })
		assert.are.same({ "Part 1", "Part 2", "Part 3" }, { steps[1].part, steps[2].part, steps[3].part })
		assert.are.same({ "5m ago", "5m ago", "1m ago" }, { steps[1].when, steps[2].when, steps[3].when })
		assert.are.equal("|cffffff00|Hquest:15:3|h[Investigate Echo Ridge]|h|r", steps[2].link)
		assert.is_true(steps[1].nested)
	end)

	it("leaves where you are unmarked when the client can't tell", function()
		local store, board = chainBoard()
		store.env.questDone = nil
		local out = View.questLog(store, board, BOB, {}, false, T0 + 400, "log", { [166] = true })
		assert.are.same({ "done", nil, "log" }, { out.rows[3].status, out.rows[4].status, out.rows[5].status })
		assert.is_nil(out.rows[4].mark)
	end)

	it("shows your own chain without marks", function()
		local store, board = chainBoard()
		local out = View.questLog(store, board, ME, {}, false, T0 + 400, "log", { [54] = true })
		assert.are.same({ 54, 54, "Part 3" }, { out.rows[1].id, out.rows[1].key, out.rows[1].part })
		assert.are.equal("Earlier in the chain", out.rows[2].text)
		assert.is_nil(out.rows[3].mark)
		assert.is_nil(out.rows[4].mark)
	end)
end)

describe("the Quests tab's completed quests", function()
	it("lists turn-ins newest first with each chain kept together and joined", function()
		local store, board = chainBoard()
		local out = View.questLog(store, board, BOB, {}, false, T0 + 400, "done")
		assert.are.equal("Bob · 1 quest", out.title)
		assert.are.equal("as of just now · you've done 1 of 4", out.detail)
		assert.are.equal("Only ones I haven't done", out.filterLabel)
		assert.is_true(out.filterable)
		local ids, joins, parts, marks = {}, {}, {}, {}
		for i, row in ipairs(out.rows) do
			ids[i] = row.id
			joins[i] = (row.up and "up" or "") .. (row.down and "down" or "")
			parts[i] = row.part
			marks[i] = row.mark or false
		end
		assert.are.same({ 54, 15, 7, 46 }, ids)
		assert.are.same({ "down", "updown", "up", "" }, joins)
		assert.are.same({ "Part 3", "Part 2", "", "" }, parts)
		assert.are.same({ Commands.LOG_ICON, false, Commands.SHARED_ICON, false }, marks)
		assert.are.same({ "1m ago", "5m ago", "5m ago", "3m ago" },
			{ out.rows[1].when, out.rows[2].when, out.rows[3].when, out.rows[4].when })
		assert.is_true(out.rows[3].shared)
		assert.are.same({ 1, 2, 3, 4 }, { out.rows[1].index, out.rows[2].index, out.rows[3].index, out.rows[4].index })
	end)

	it("filters to the ones you haven't done", function()
		local store, board = chainBoard()
		local out = View.questLog(store, board, BOB, {}, true, T0 + 400, "done")
		assert.are.same({ 54, 15, 46 }, { out.rows[1].id, out.rows[2].id, out.rows[3].id })
		assert.are.same({ true, false }, { out.rows[1].down, out.rows[1].up })
		assert.is_true(out.rows[2].up)
		assert.is_false(out.rows[2].down)
		store.env.questDone = function()
			return true
		end
		store:questLog({})
		out = View.questLog(store, board, BOB, {}, true, T0 + 400, "done")
		assert.are.same({}, out.rows)
		assert.are.equal("You've done all of these too.", out.empty)
	end)

	it("shows your own unmarked, and says when nothing's been turned in", function()
		local store, board = chainBoard()
		local mine = View.questLog(store, board, ME, {}, true, T0 + 400, "done")
		assert.are.equal("What members of this board see.", mine.detail)
		assert.is_nil(mine.filterable)
		assert.are.equal(1, #mine.rows)
		assert.is_nil(mine.rows[1].mark)
		local fresh = newStore()
		local empty = fresh:createBoard("Empty")
		fresh:questLog(quests(7, 5))
		assert.are.equal("Nothing turned in yet. Quests show up here as your character hands them in.",
			View.questLog(fresh, empty, ME, {}, false, T0, "done").empty)
		remoteLog(store, board, BOB, "7:5")
		assert.are.equal("Nothing turned in yet. Quests show up here as Bob hands them in.",
			View.questLog(store, board, BOB, {}, false, T0, "done").empty)
		assert.are.same({ log = 0, done = 0 }, View.questLog(store, board, "Carol-Realm", {}, false, T0, "done").counts)
	end)

	it("lists the last few in /cork quests <name>", function()
		local store = chainBoard()
		store.env.now = function()
			return T0 + 400
		end
		local out = Commands.run(store, "quests bob")
		assert.are.equal("Last turned in: " .. Commands.questLink(54, 7, "Report to Goldshire") .. " |cff808080(1m)|r, "
			.. Commands.questLink(46, 10, "Bounty on Murlocs") .. " |cff808080(3m)|r, "
			.. Commands.questLink(15, 3, "Investigate Echo Ridge") .. " |cff808080(5m)|r"
			.. " |cff808080and 1 more on the Quests tab|r", out[#out])
		out = Commands.run(store, "quests will")
		assert.matches("^Last turned in: .-Kobold Camp Cleanup.-%(6m%)|r$", out[#out])
	end)
end)

describe("completed quests in game", function()
	local MCBRIDE = "Creature-0-4372-0-1-197-000000"
	local GOLDSHIRE = "Creature-0-4372-0-1-240-000000"

	local function boards(client)
		return client.env.CorkboardDB.global.boards
	end

	local function party()
		local network = Client.Network.new()
		local clients = {}
		local logs = {
			{ { id = 7, level = 5 }, { id = 46, level = 10 }, { id = 166, level = 18 } },
			{ { id = 7, level = 5 }, { id = 54, level = 7 } },
		}
		for i, name in ipairs({ "Will", "Bob" }) do
			clients[i] = Client.new({
				network = network,
				name = name,
				guid = "Player-4372-0000000" .. i,
				class = i == 1 and "WARRIOR" or "MAGE",
				quests = logs[i],
			}):login()
		end
		network:advance(10, clients)
		local a, b = clients[1], clients[2]
		a:createBoard("Molten Core prep")
		local code = a:slash("/cork invite"):match("(CORK1:%S+)")
		b:slash("/cork join " .. code)
		network:advance(30, clients)
		a:setQuests()
		b:setQuests()
		network:advance(10, clients)
		return network, clients, a.ns.Corkboard.store:current().id
	end

	local function logOf(client, id, who)
		return client.ns.Store.questLogs(boards(client)[id])[who]
	end

	local function ids(list)
		local out = {}
		for i = 1, list.count do
			out[i] = list.elements[i].data.id or "caption"
		end
		return out
	end

	it("learns a chain from a turn-in and the next part, and shows it on the Quests tab", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:turnInQuest(7, MCBRIDE)
		a:advance(5)
		a:acceptQuest(15, 3, MCBRIDE)
		network:advance(10, clients)
		local text = logOf(b, id, a:fullName()).text
		assert.matches("^15:3/7,46:10,166:18\nD1;7%.5%.%d+$", text)
		assert.are.equal(7, a.env.CorkboardDB.global.questLinks[15])

		b:slash("/cork")
		b.env.CorkboardFrameTab5:Click()
		local ui = b.ns.Quests.Widgets()
		assert.are.equal("Will · 3 quests", ui.title.text)
		assert.are.equal("Quest log (3)", ui.modes[1].text)
		assert.are.equal("Completed (1)", ui.modes[2].text)
		assert.is_false(ui.modes[1]:IsEnabled())
		assert.are.equal("Only quests I'm on too", ui.onlyShared.label.text)

		-- 15 is the second part of a chain: a click lists the first.
		local list = ui.quests
		assert.are.same({ 15, 46, 166 }, ids(list))
		local row = list.elements[1]
		assert.are.equal("Part 2", row.part.text)
		assert.is_true(row.toggle.shown)
		assert.is_false(list.elements[2].toggle.shown)
		row:Click()
		assert.are.same({ 15, "caption", 7, 46, 166 }, ids(list))
		assert.are.equal("Earlier in the chain · you've done 0 of 1", list.elements[2].caption.text)
		assert.are.equal(b.ns.Commands.LOG_ICON, list.elements[3].data.mark) -- Bob is on 7 himself
		assert.are.equal("|cffffff00|Hquest:7:5|h[Kobold Camp Cleanup]|h|r", list.elements[3].text.text)
		assert.are.equal("just now", list.elements[3].when.text)
		list.elements[1]:Click()
		assert.are.same({ 15, 46, 166 }, ids(list))

		-- Completed: what Will turned in, marked where Bob is with it.
		ui.modes[2]:Click()
		assert.is_false(ui.modes[2]:IsEnabled())
		assert.is_true(ui.modes[1]:IsEnabled())
		assert.are.same({ 7 }, ids(list))
		assert.are.equal("Only ones I haven't done", ui.onlyShared.label.text)
		assert.matches("you've done 0 of 1$", ui.detail.text)
		assert.are.equal(b.ns.Commands.LOG_ICON, list.elements[1].data.mark)
		assert.is_true(list.elements[1]:GetScript("OnHyperlinkEnter") ~= nil)

		-- Once Bob turns 7 in too, it's ticked, and the filter hides it.
		b:turnInQuest(7, MCBRIDE)
		network:advance(10, clients)
		assert.are.equal(b.ns.Commands.SHARED_ICON, list.elements[1].data.mark)
		ui.onlyShared:SetChecked(true)
		ui.onlyShared:Click()
		assert.are.equal(0, list.count)
		assert.are.equal("You've done all of these too.", ui.empty.text)
		ui.modes[1]:Click() -- the filter doesn't carry over
		assert.is_false(ui.onlyShared:GetChecked())
		assert.are.equal(3, list.count)
	end)

	it("doesn't link a quest taken from someone else, or taken later", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:turnInQuest(7, MCBRIDE)
		a:acceptQuest(15, 3, GOLDSHIRE)
		a:turnInQuest(46, MCBRIDE)
		a:advance(61)
		a:acceptQuest(54, 7, MCBRIDE)
		network:advance(10, clients)
		local text = logOf(b, id, a:fullName()).text
		assert.matches("^15:3,54:7,166:18\nD1;46%.10%.%d+,7%.5%.%d+$", text)
		assert.is_nil(a.env.CorkboardDB.global.questLinks[15])
	end)

	it("keeps completed quests and chains across a /reload", function()
		local network, clients, id = party()
		local a = clients[1]
		a:turnInQuest(7, MCBRIDE)
		a:acceptQuest(15, 3, MCBRIDE)
		network:advance(10, clients)
		local rev = logOf(a, id, a:fullName()).rev
		a = a:reload()
		clients[1] = a
		assert.are.equal(7, a:store():myDone()[1].id)
		a:setQuests()
		network:advance(10, clients)
		assert.are.equal(rev, logOf(clients[2], id, a:fullName()).rev)
		assert.matches("^15:3/7", logOf(a, id, a:fullName()).text)
	end)
end)
