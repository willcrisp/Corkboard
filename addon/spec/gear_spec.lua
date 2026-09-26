-- The gear feed (docs/design.md §9.1): rare and better items a member equips
-- for the first time are posted to their boards as gear-kind notes.

local Store = require("Core.Store")
local View = require("Core.View")
local Client = require("helpers.client")

local T0 = 1790000000
local ME = "Will-Realm"
local PREFIX = "a1b2c3d4"
local BLUE = "|cff0070dd|Hitem:9832::::::::20:::::::::|h[Tidal Charm]|h|r"
local PURPLE = "|cffa335ee|Hitem:17010::::::::60:::::::::|h[Fiery Core]|h|r"
local GREEN = "|cff1eff00|Hitem:2327::::::::20:::::::::|h[Handstitched Leather Vest]|h|r"

local function newStore()
	local db = { global = { boards = {} }, char = {} }
	local t, seed = T0, 1
	local env = {
		now = function()
			t = t + 1
			return t
		end,
		rand = function(n)
			seed = seed * 16807 % 2147483647 -- Park-Miller, as in store_spec
			return seed % n + 1
		end,
		me = ME,
		prefix = PREFIX,
	}
	return Store.new(db, env), db, env
end

describe("Store:equipped", function()
	it("posts a rare or better item to every board with gear posts on", function()
		local store = newStore()
		local a = store:createBoard("Raid")
		local b = store:createBoard("Guild")
		assert.are.equal(2, store:equipped(9832, BLUE, 3))
		for _, board in ipairs({ a, b }) do
			local entries = Store.gear(board)
			assert.are.equal(1, #entries)
			assert.are.equal("gear", entries[1].kind)
			assert.are.equal(BLUE, entries[1].text)
			assert.are.equal(ME, entries[1].author)
		end
	end)

	it("skips greens and anything without a quality", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		assert.are.equal(0, store:equipped(2327, GREEN, 2))
		assert.are.equal(0, store:equipped(1234, "|cffffffff|Hitem:1234|h[Thing]|h|r", nil))
		assert.are.same({}, Store.gear(board))
	end)

	it("posts an item only the first time this character equips it", function()
		local store, db = newStore()
		local board = store:createBoard("Raid")
		assert.are.equal(1, store:equipped(9832, BLUE, 3))
		assert.are.equal(0, store:equipped(9832, BLUE, 3))
		assert.are.equal(1, #Store.gear(board))
		assert.is_true(db.char.gearSeen[9832])
	end)

	it("only marks items seen when seeding", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		assert.are.equal(0, store:equipped(17010, PURPLE, 4, true))
		assert.are.equal(0, store:equipped(17010, PURPLE, 4))
		assert.are.same({}, Store.gear(board))
	end)

	it("respects the per-board option and removal", function()
		local store = newStore()
		local off = store:createBoard("Quiet")
		local gone = store:createBoard("Old guild")
		local on = store:createBoard("Raid")
		assert.is_true(off.gear)
		store:setOption(off.id, "gear", false)
		gone.members[ME].removed = true
		assert.are.equal(1, store:equipped(9832, BLUE, 3))
		assert.are.equal(0, #Store.gear(off))
		assert.are.equal(0, #Store.gear(gone))
		assert.are.equal(1, #Store.gear(on))
	end)

	it("waits for the player's name, without marking the item seen", function()
		local store, db, env = newStore()
		store:createBoard("Raid")
		env.me = nil
		assert.are.same({ nil, "identity" }, { store:equipped(9832, BLUE, 3) })
		assert.is_nil(db.char.gearSeen)
	end)

	it("keeps gear out of the note list, and lists it newest first", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:addNote(board.id, "Bring flasks")
		store:equipped(9832, BLUE, 3)
		store:equipped(17010, PURPLE, 4)
		local notes = Store.notes(board)
		assert.are.equal(1, #notes)
		assert.are.equal("Bring flasks", notes[1].text)
		local entries = Store.gear(board)
		assert.are.equal(PURPLE, entries[1].text)
		assert.are.equal(BLUE, entries[2].text)
		local rows = View.gearRows(entries, 1, entries[1].created + 120, "Realm")
		assert.are.equal(1, #rows)
		assert.are.same({ index = 1, who = "Will", link = PURPLE, age = View.shortAge(120) }, rows[1])
	end)
end)

describe("the gear feed in game", function()
	local function boards(client)
		return client.env.CorkboardDB.global.boards
	end

	local function party()
		local network = Client.Network.new()
		local clients = {}
		for i, name in ipairs({ "Will", "Bob" }) do
			clients[i] = Client.new({
				network = network,
				name = name,
				guid = "Player-4372-0000000" .. i,
				-- Will already wears the purple: seeded at login, never posted.
				equipped = i == 1 and { [13] = { link = PURPLE, quality = 4 } } or nil,
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

	it("posts a new blue to the board and shows it to other members", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:equip(13, nil) -- unequipping posts nothing
		a:equip(13, PURPLE, 4) -- re-equipping what was worn at login posts nothing
		a:equip(5, GREEN, 2) -- nor does a green
		a:equip(14, BLUE, 3)
		network:advance(10, clients)
		local entries = Store.gear(boards(b)[id])
		assert.are.equal(1, #entries)
		assert.are.equal(BLUE, entries[1].text)
		assert.are.equal("Will-MirageRaceway", entries[1].author)
		assert.are.same({}, a.ns.Store.notes(boards(b)[id]))

		-- B's Gear tab lists it, with a working link.
		b:slash("/cork")
		b.env.CorkboardFrameTab3:Click()
		local ui = b.ns.Gear.Widgets()
		assert.is_true(ui.post:GetChecked())
		local row = ui.list.elements[1]
		assert.is_true(row:IsVisible())
		assert.are.equal("Will equipped " .. BLUE, row.text.text)
		assert.is_function(row:GetScript("OnHyperlinkEnter"))

		-- Unticking the option stops B's gear going to this board.
		ui.post:SetChecked(false)
		ui.post:Click()
		assert.is_false(boards(b)[id].gear)
		b:equip(1, PURPLE, 4)
		assert.are.equal(1, #Store.gear(boards(b)[id]))
		b.env.CorkboardFrameTab1:Click()
		assert.is_false(ui.list:IsVisible())
	end)

	it("keeps what it has seen across a /reload", function()
		local network, clients, id = party()
		local a = clients[1]
		a:equip(14, BLUE, 3)
		a = a:reload()
		clients[1] = a
		a:equip(14, nil)
		a:equip(14, BLUE, 3)
		network:advance(10, clients)
		assert.are.equal(1, #Store.gear(boards(a)[id]))
	end)
end)
