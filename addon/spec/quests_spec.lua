-- Quest logs (docs/design.md §9.3): each member's quest log is one
-- quests-kind note of "id:level" pairs, shown on the Quests tab and by
-- /cork quests, with the quests you're on too marked.

local Store = require("Core.Store")
local View = require("Core.View")
local Commands = require("Core.Commands")
local Sanitise = require("Core.Sanitise")
local Invite = require("Core.Invite")
local Client = require("helpers.client")

local T0 = 1790000000
local ME = "Will-Realm"
local BOB = "Bob-Realm"
local PREFIX = "a1b2c3d4"
local TITLES = { [7] = "Kobold Camp Cleanup", [46] = "Bounty on Murlocs", [166] = "The Defias Brotherhood" }

local function newStore(options)
	options = options or {}
	local db = { global = { boards = {} }, char = {} }
	local t, seed = T0, options.seed or 1
	local env = {
		now = function()
			t = t + 1
			return t
		end,
		rand = function(n)
			seed = seed * 16807 % 2147483647 -- Park-Miller, as in store_spec
			return seed % n + 1
		end,
		me = options.me or ME,
		prefix = options.prefix or PREFIX,
		questTitle = function(id)
			return TITLES[id]
		end,
	}
	return Store.new(db, env), db, env
end

local function log(store, board, who)
	return Store.questLogs(store:board(board.id) or board)[who or ME]
end

local function quests(...)
	local list = {}
	for i = 1, select("#", ...), 2 do
		list[#list + 1] = { id = select(i, ...), level = select(i + 1, ...) }
	end
	return list
end

describe("Store.encodeQuests and decodeQuests", function()
	it("writes id:level pairs by id, once each", function()
		assert.are.equal("7:5,46:10,166:18", Store.encodeQuests(quests(166, 18, 7, 5, 46, 10, 7, 5)))
		assert.are.same(quests(7, 5, 46, 10, 166, 18), Store.decodeQuests("7:5,46:10,166:18"))
	end)

	it("skips what isn't a quest, and stores a missing level as 0", function()
		local text = Store.encodeQuests({ { id = 0, level = 1 }, { id = 1.5 }, { id = "x" }, { id = 9 },
			{ id = 1e10, level = 1 }, { id = 12, level = -3 } })
		assert.are.equal("9:0,12:0", text)
		assert.are.same(quests(9, 0, 12, 60), Store.decodeQuests("9:0;junk,12:60:extra,0:5,x:1"))
		assert.are.same({}, Store.decodeQuests(""))
		assert.are.same({}, Store.decodeQuests(nil))
	end)

	it("keeps a full log well inside a note", function()
		local list = {}
		for i = 1, 60 do
			list[i] = { id = 90000 + i, level = 60 }
		end
		local text = Store.encodeQuests(list)
		assert.are.equal(Store.QUESTS_MAX, #Store.decodeQuests(text))
		assert.is_true(#text < Sanitise.MAX_TEXT / 3)
		assert.is_true(Sanitise.text(text))
	end)
end)

describe("Store:questLog", function()
	it("shares the log with every board, as one quests note per character", function()
		local store, db = newStore()
		local a = store:createBoard("Raid")
		local b = store:createBoard("Guild")
		assert.are.same({ 2, true }, { store:questLog(quests(7, 5, 166, 18)) })
		assert.are.equal("7:5,166:18", db.char.quests)
		for _, board in ipairs({ a, b }) do
			local note = log(store, board)
			assert.are.equal("quests", note.kind)
			assert.are.equal("7:5,166:18", note.text)
			assert.are.equal(ME, note.author)
		end
		assert.are.same({}, Store.notes(a))
		assert.are.same({}, Store.gear(a))
		assert.are.same({ [7] = true, [166] = true }, store:myQuests())
	end)

	it("writes nothing for an unchanged log, and edits the same note for a new one", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:questLog(quests(7, 5))
		local first = log(store, board)
		local rev, id = first.rev, first.id
		assert.are.same({ 0, false }, { store:questLog(quests(7, 5)) })
		assert.are.equal(rev, log(store, board).rev)
		assert.are.same({ 1, true }, { store:questLog(quests(7, 5, 46, 10)) })
		local second = log(store, board)
		assert.are.equal(id, second.id)
		assert.is_true(second.rev > rev)
		assert.are.equal("7:5,46:10", second.text)
		-- An empty log is shared too: the member is on no quests.
		store:questLog({})
		assert.are.equal("", log(store, board).text)
	end)

	it("follows the per-board option and removal", function()
		local store = newStore()
		local quiet = store:createBoard("Quiet")
		local gone = store:createBoard("Old guild")
		assert.is_true(quiet.quests)
		store:setOption(quiet.id, "quests", false)
		gone.members[ME].removed = true
		store:questLog(quests(7, 5))
		assert.is_nil(log(store, quiet))
		assert.is_nil(log(store, gone))

		-- Turning it on shares the log at once; off again deletes it.
		store:setOption(quiet.id, "quests", true)
		local first = log(store, quiet)
		assert.are.equal("7:5", first.text)
		store:setOption(quiet.id, "quests", false)
		assert.is_nil(log(store, quiet))
		local tomb = quiet.notes[first.id]
		assert.is_true(tomb.deleted)
		-- On again: a newer live version of the same record beats the tombstone.
		store:setOption(quiet.id, "quests", true)
		local again = log(store, quiet)
		assert.are.equal(first.id, again.id)
		assert.is_true(again.rev > tomb.rev)
		assert.are.equal("7:5", again.text)
	end)

	it("shares the log with a board made or joined later", function()
		local store = newStore()
		store:questLog(quests(7, 5))
		local made = store:createBoard("Raid")
		assert.are.equal("7:5", log(store, made).text)
		local other = newStore({ me = BOB, prefix = "0badf00d", seed = 7 })
		local theirs = other:createBoard("Theirs")
		local joined = store:joinBoard(Invite.encode(theirs))
		assert.are.equal("7:5", log(store, joined).text)
	end)

	it("keeps the log while the player's name isn't known", function()
		local store, db, env = newStore()
		local board = store:createBoard("Raid")
		env.me = nil
		assert.are.same({ nil, "identity" }, { store:questLog(quests(7, 5)) })
		assert.are.equal("7:5", db.char.quests)
		assert.is_nil(log(store, board))
		env.me = ME
		assert.are.same({ 1, false }, { store:questLog(quests(7, 5)) })
	end)

	it("keeps the log on its own id, apart from the character's notes", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:questLog(quests(7, 5))
		assert.are.equal(PREFIX .. "-0", log(store, board).id)
		assert.are.equal(PREFIX .. "-0001", store:addNote(board.id, "Bring flasks").id)

		-- Another install of the same character writes the same record, so its
		-- newer log replaces this one rather than sitting beside it.
		local copy = {}
		for k, v in pairs(log(store, board)) do
			copy[k] = v
		end
		copy.rev, copy.text = board.clock + 5, "46:10"
		assert.are.same({ copy.id }, store:applyRemote(board.id, { notes = { copy } }).notes)
		assert.are.equal("46:10", log(store, board).text)
		assert.are.equal("Bring flasks", Store.notes(board)[1].text)
	end)

	it("counts the newer log when an author somehow has two", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		local function remote(id, rev, text)
			store:applyRemote(board.id, { notes = { {
				id = id, author = BOB, created = T0, rev = rev, editor = BOB, color = 1, deleted = false,
				kind = "quests", text = text,
			} } })
		end
		remote("0badf00d-0", T0 + 200, "7:5")
		remote("0badf00e-0", T0 + 100, "46:10")
		assert.are.equal("7:5", Store.questLogs(board)[BOB].text)
	end)
end)

-- A board where Bob shares 7, 46 and 99 (a quest this client can't name yet),
-- and Will is on 7 and 166.
local function sharedBoard()
	local store, db = newStore()
	local board = store:createBoard("Raid")
	store:questLog(quests(7, 5, 166, 18))
	local now = T0 + 100
	assert.is_true(store:applyRemote(board.id, { notes = { {
		id = "0badf00d-0001", author = BOB, created = now, rev = now, editor = BOB, color = 1, deleted = false,
		kind = "quests", text = "7:5,46:10,99:3",
	} } }).notes[1] ~= nil)
	return store, board, db
end

describe("the Quests tab's view", function()
	it("lists others by name, then you, with counts", function()
		local store, board = sharedBoard()
		board.seen = { [BOB] = { at = T0 + 100, class = "ROGUE" } }
		local rows = View.questMembers(store, board, { BOB })
		assert.are.same({
			{ index = 1, name = BOB, label = "Bob", you = false, online = true, class = "ROGUE", detail = "3 · 1 shared" },
			{ index = 2, name = ME, label = "You", you = true, online = true, detail = "2 quests" },
		}, rows)
	end)

	it("shows a member's quests by level, marking the shared ones", function()
		local store, board = sharedBoard()
		local out = View.questLog(store, board, BOB, {}, false, T0 + 400)
		assert.are.equal("Bob · 3 quests", out.title)
		assert.are.equal("as of 5m ago · you share 1 quest with Bob", out.detail)
		assert.is_true(out.filterable)
		assert.are.same({ 99, 7, 46 }, { out.rows[1].id, out.rows[2].id, out.rows[3].id })
		assert.are.equal(Commands.questLink(99, 3, "Quest #99"), out.rows[1].link)
		assert.are.equal("|cffffff00|Hquest:7:5|h[Kobold Camp Cleanup]|h|r", out.rows[2].link)
		assert.are.same({ false, true, false }, { out.rows[1].shared, out.rows[2].shared, out.rows[3].shared })
		assert.is_nil(out.empty)

		out = View.questLog(store, board, BOB, { BOB }, true, T0 + 400)
		assert.are.equal("online now · you share 1 quest with Bob", out.detail)
		assert.are.equal(1, #out.rows)
		assert.are.equal(7, out.rows[1].id)
	end)

	it("counts a member's last message towards how current their log is", function()
		local store, board = sharedBoard()
		board.seen = { [BOB] = { at = T0 + 3700 } }
		assert.are.equal("as of 5m ago · you share 1 quest with Bob",
			View.questLog(store, board, BOB, {}, false, T0 + 4000).detail)
	end)

	it("shows your own log unmarked, and explains a missing one", function()
		local store, board = sharedBoard()
		local mine = View.questLog(store, board, ME, {}, false, T0)
		assert.are.equal("You · 2 quests", mine.title)
		assert.is_nil(mine.filterable)
		assert.are.same({ false, false }, { mine.rows[1].shared, mine.rows[2].shared })
		assert.are.equal("Carol-Other doesn't share a quest log on this board.",
			View.questLog(store, board, "Carol-Other", {}, false, T0).empty)
		local empty = newStore():createBoard("Empty")
		assert.are.same({}, View.questMembers(store, empty, {}))
		assert.matches("^Nobody shares", View.questLog(store, empty, nil, {}, false, T0).empty)
		local none = View.questLog(store, board, BOB, {}, true, T0)
		assert.are.equal(1, #none.rows)
		store:questLog(quests(2040, 30))
		assert.are.equal("None of these are in your quest log.", View.questLog(store, board, BOB, {}, true, T0).empty)
	end)
end)

describe("/cork quests", function()
	it("lists who shares a quest log", function()
		local store, board = sharedBoard()
		board.seen = { [BOB] = { at = T0 + 100 } }
		store.env.now = function()
			return T0 + 7300
		end
		assert.are.same({
			"Quest logs on Raid:",
			"  Bob: 3 quests, 1 shared with you |cff808080(as of 2h ago)|r",
			"  You: 2 quests",
			"|cff808080/cork quests <name> lists someone's quests.|r",
		}, Commands.run(store, "quests"))
	end)

	it("lists one member's quests, by any part of their name", function()
		local store = sharedBoard()
		local out = Commands.run(store, "quests bo")
		assert.matches("^Bob is on 3 quests |cff808080%(as of .-%)|r%. You share 1%.$", out[1])
		assert.are.equal("  " .. Commands.questLink(99, 3, "Quest #99") .. " |cff808080(3)|r", out[2])
		assert.are.equal("  " .. Commands.questLink(7, 5, "Kobold Camp Cleanup") .. " |cff808080(5)|r |T"
			.. Commands.SHARED_ICON .. ":0|t", out[3])
		assert.are.equal(4, #out)
		assert.are.same(out, Commands.run(store, "quests BOB-realm"))
		out = Commands.run(store, "quests will")
		assert.are.equal("You're on 2 quests, shared with Raid.", out[1])
		assert.is_nil(out[2]:find("|T", 1, true))
	end)

	it("says when a name matches nobody, or several", function()
		local store, board = sharedBoard()
		assert.matches("Nobody called \"carol\"", Commands.run(store, "quests carol")[1])
		store:applyRemote(board.id, { notes = { {
			id = "0badf00e-0001", author = "Bobby-Realm", created = T0, rev = T0 + 200, editor = "Bobby-Realm",
			color = 1, deleted = false, kind = "quests", text = "",
		} } })
		assert.matches("^Bob is on", Commands.run(store, "quests bob")[1])
		assert.matches("could be Bob%-Realm or Bobby%-Realm", Commands.run(store, "quests b")[1])
		local empty = newStore()
		empty:createBoard("Empty")
		assert.are.same({ "Nobody on Empty shares a quest log yet." }, Commands.run(empty, "quests"))
	end)

	it("turns sharing on and off", function()
		local store, board = sharedBoard()
		assert.are.same({ "Sharing your quest log for Raid is off." }, Commands.run(store, "quests off"))
		assert.is_false(board.quests)
		assert.is_nil(log(store, board))
		Commands.run(store, "quests ON")
		assert.are.equal("7:5,166:18", log(store, board).text)
	end)
end)

describe("quest logs in game", function()
	local function boards(client)
		return client.env.CorkboardDB.global.boards
	end

	local function party()
		local network = Client.Network.new()
		local clients = {}
		local logs = {
			{ { header = "Elwynn Forest" }, { id = 7, level = 5 }, { id = 46, level = 10 },
				{ header = "Westfall" }, { id = 166, level = 18 } },
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
		return network, clients, a.ns.Corkboard.store:current().id
	end

	local function logOf(client, id, who)
		return client.ns.Store.questLogs(boards(client)[id])[who]
	end

	it("waits for the client's first QUEST_LOG_UPDATE before sharing", function()
		local network, clients, id = party()
		local a = clients[1]
		assert.is_nil(logOf(a, id, a:fullName()))
		a:setQuests()
		network:advance(10, clients)
		assert.are.equal("7:5,46:10,166:18", logOf(a, id, a:fullName()).text)
		assert.are.equal("7:5,46:10,166:18", logOf(clients[2], id, a:fullName()).text)
	end)

	it("shows who is on what on the Quests tab", function()
		local network, clients = party()
		local a, b = clients[1], clients[2]
		a:setQuests()
		b:setQuests()
		network:advance(10, clients)

		b:slash("/cork")
		b.env.CorkboardFrameTab5:Click()
		local ui = b.ns.Quests.Widgets()
		assert.is_true(ui.share:GetChecked())
		local members = ui.members.elements
		assert.are.equal("Will", members[1].name.text)
		assert.are.equal("3 · 1 shared", members[1].detail.text)
		assert.are.equal("You", members[2].name.text)
		assert.is_true(members[1].selected.shown)
		assert.are.equal("Will · 3 quests", ui.title.text)
		assert.are.equal("online now · you share 1 quest with Will", ui.detail.text)

		-- Sorted by level, the shared quest ticked. Bob's client hasn't seen
		-- quest 46 or 166 yet: it asks for them and the names follow.
		local rows = ui.quests.elements
		assert.are.equal(3, ui.quests.count)
		assert.are.same({ 7, 46, 166 }, { rows[1].data.id, rows[2].data.id, rows[3].data.id })
		assert.is_true(rows[1].mark.shown)
		assert.is_false(rows[2].mark.shown)
		assert.are.equal("|cffffff00|Hquest:7:5|h[Kobold Camp Cleanup]|h|r", rows[1].text.text)
		assert.are.equal("|cffffff00|Hquest:46:10|h[Quest #46]|h|r", rows[2].text.text)
		assert.are.equal("10", rows[2].level.text)
		assert.is_function(rows[1]:GetScript("OnHyperlinkEnter"))
		assert.are.same({ 46, 166 }, b.questRequests)
		b:advance(1)
		assert.are.equal("|cffffff00|Hquest:46:10|h[Bounty on Murlocs]|h|r", rows[2].text.text)
		assert.are.equal("|cffffff00|Hquest:166:18|h[The Defias Brotherhood]|h|r", rows[3].text.text)

		-- Only the quests Bob is on too.
		ui.onlyShared:SetChecked(true)
		ui.onlyShared:Click()
		assert.are.equal(1, ui.quests.count)
		ui.onlyShared:SetChecked(false)
		ui.onlyShared:Click()
		assert.are.equal(3, ui.quests.count)

		-- Bob's own log, unticked.
		members[2]:Click()
		assert.are.equal("You · 2 quests", ui.title.text)
		assert.is_false(ui.onlyShared:IsShown())
		assert.is_false(ui.quests.elements[1].mark.shown)

		-- A member picked on the Members tab opens here.
		b.env.CorkboardFrameTab2:Click()
		local roster = b.ns.Members.Widgets().list.elements
		for _, row in ipairs(roster) do
			if row.member == a:fullName() then
				row:Click()
			end
		end
		assert.is_true(ui.quests:IsVisible())
		assert.are.equal("Will · 3 quests", ui.title.text)
	end)

	it("follows quests picked up and dropped, and sends nothing for objective progress", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:setQuests()
		b:setQuests()
		network:advance(10, clients)
		local rev = logOf(b, id, a:fullName()).rev
		a:setQuests() -- a kill with an objective: same log
		network:advance(10, clients)
		assert.are.equal(rev, logOf(a, id, a:fullName()).rev)

		a:setQuests({ { id = 7, level = 5 }, { id = 2040, level = 30 } }) -- turned in 46 and 166, took 2040
		network:advance(10, clients)
		assert.are.equal("7:5,2040:30", logOf(b, id, a:fullName()).text)

		local lines = b:slash("/cork quests will")
		assert.matches("Will is on 2 quests", lines)
		assert.truthy(lines:find("[Kobold Camp Cleanup]|h|r |cff808080(5)|r |T", 1, true))
	end)

	it("stops sharing when the box is unticked", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:setQuests()
		network:advance(10, clients)
		a:slash("/cork")
		a.env.CorkboardFrameTab5:Click()
		local ui = a.ns.Quests.Widgets()
		ui.share:SetChecked(false)
		ui.share:Click()
		network:advance(10, clients)
		assert.is_nil(logOf(b, id, a:fullName()))
		a:setQuests({ { id = 15, level = 3 } })
		network:advance(10, clients)
		assert.is_nil(logOf(b, id, a:fullName()))
	end)

	it("keeps the log across a /reload without sending it again", function()
		local network, clients, id = party()
		local a = clients[1]
		a:setQuests()
		network:advance(10, clients)
		local rev = logOf(a, id, a:fullName()).rev
		a = a:reload()
		clients[1] = a
		assert.is_true(a:store():myQuests()[166])
		a:setQuests()
		network:advance(10, clients)
		assert.are.equal(rev, logOf(a, id, a:fullName()).rev)
		assert.are.equal(rev, logOf(clients[2], id, a:fullName()).rev)
	end)
end)
