-- Player notes (docs/design.md §9.4): a board's avoid list and good-player
-- list, as player-kind notes, shown on the Players tab, by /cork player, on
-- unit tooltips and as a warning when an avoided player joins your group.

local Store = require("Core.Store")
local View = require("Core.View")
local Commands = require("Core.Commands")
local Players = require("Core.Players")
local Sanitise = require("Core.Sanitise")
local Client = require("helpers.client")

local T0 = 1790000000
local ME = "Will-Realm"
local BOB = "Bob-Realm"
local PREFIX = "a1b2c3d4"
local LINK = "|cff0070dd|Hitem:9832::::::::20:::::::::|h[Tidal Charm]|h|r"

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
			seed = seed * 16807 % 2147483647 -- Park-Miller, as in store_spec
			return seed % n + 1
		end,
		me = options.me or ME,
		prefix = options.prefix or PREFIX,
	}
	return Store.new(db, env), db, env
end

describe("Players.encode and decode", function()
	it("writes a header line and the reason, and reads them back", function()
		local text = Players.encode("Gankalot", "avoid", "Rolled need on " .. LINK .. " and left.")
		assert.are.equal("P1;avoid;Gankalot\nRolled need on " .. LINK .. " and left.", text)
		assert.are.same({ name = "Gankalot", verdict = "avoid", reason = "Rolled need on " .. LINK .. " and left.",
			key = "gankalot" }, Players.decode(text))
		assert.is_true(Sanitise.text(text))
	end)

	it("tidies the name and reason, and leaves out an empty reason", function()
		assert.are.equal("P1;good;Aprune Proudshield", Players.encode("  Aprune   Proudshield ", "good", " \n "))
		assert.are.equal("P1;avoid;Bob Realm", Players.encode("Bob\nRealm", "avoid")) -- a pasted line break
		assert.are.equal("P1;good;Bob-Realm\nHealed\nall night", Players.encode("Bob-Realm", "good", "\nHealed\nall night  "))
		assert.are.same({ name = "Aprune Proudshield", verdict = "good", reason = "", key = "aprune" },
			Players.decode("P1;good;Aprune Proudshield"))
	end)

	it("refuses names that can't go in the header", function()
		for _, name in ipairs({ "", "   ", "Bob;Realm", "Bob|Realm", "Bob\1", "-Realm", "--", string.rep("a", 65),
			"Bo\255b", 7 }) do
			assert.are.same({ nil, "player_name" }, { Players.encode(name, "avoid", "") }, tostring(name))
		end
		assert.are.equal("P1;avoid;" .. string.rep("a", 64), Players.encode(string.rep("a", 64), "avoid"))
		assert.are.equal("P1;avoid;Zoë", Players.encode("Zoë", "avoid"))
	end)

	it("needs a known verdict, and text the sanitiser takes", function()
		assert.are.same({ nil, "verdict" }, { Players.encode("Bob", "meh", "") })
		assert.are.same({ nil, "verdict" }, { Players.encode("Bob", nil, "") })
		assert.are.same({ nil, "escape" }, { Players.encode("Bob", "avoid", "|TInterface\\Icons\\X:0|t") })
		assert.are.same({ nil, "link_type" }, { Players.encode("Bob", "avoid", "|Hplayer:Bob|h[Bob]|h") })
		assert.are.same({ nil, "too_long" }, { Players.encode("Bob", "avoid", string.rep("x", 1990)) })
	end)

	it("ignores text it doesn't understand", function()
		for _, text in ipairs({ "P1;caution;Bob", "P2;avoid;Bob", "P1;avoid;", "P1;Avoid;Bob", "P1;avoid;Bob;x",
			"P1;avoid; Bob", "hello", "", 5 }) do
			assert.is_nil(Players.decode(text), tostring(text))
		end
	end)

	it("matches on the first name, whatever else the name carries", function()
		for _, name in ipairs({ "Aprune", "aprune", "Aprune-Realm", "Aprune Proudshield", "Aprune Proudshield-Realm",
			"  APRUNE " }) do
			assert.are.equal("aprune", Players.key(name), name)
		end
		assert.is_nil(Players.key("-Realm"))
		assert.is_nil(Players.key(""))
		assert.is_nil(Players.key(nil))
	end)
end)

describe("Store:addPlayer and editPlayer", function()
	it("adds player-kind notes, kept out of the note list", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:addNote(board.id, "Bring flasks")
		local note = assert(store:addPlayer(board.id, "Gankalot", "avoid", "Ninja'd the chest"))
		assert.are.equal("player", note.kind)
		assert.are.equal(ME, note.author)
		assert.are.equal(PREFIX .. "-0002", note.id)
		assert.are.equal(1, #Store.notes(board))
		local entries = Players.entries(board)
		assert.are.equal(1, #entries)
		assert.are.equal("Gankalot", entries[1].name)
		assert.are.equal(note, entries[1].note)
	end)

	it("passes on encoding and store errors", function()
		local store, _, env = newStore()
		local board = store:createBoard("Raid")
		assert.are.same({ nil, "player_name" }, { store:addPlayer(board.id, "", "avoid", "") })
		assert.are.same({ nil, "verdict" }, { store:addPlayer(board.id, "Bob", "maybe", "") })
		assert.are.same({ nil, "missing" }, { store:addPlayer("nope", "Bob", "avoid", "") })
		env.me = nil
		assert.are.same({ nil, "identity" }, { store:addPlayer(board.id, "Bob", "avoid", "") })
	end)

	it("edits an entry as any member, and writes nothing when it's unchanged", function()
		local store, db = newStore()
		local board = store:createBoard("Raid")
		local note = store:addPlayer(board.id, "Gankalot", "avoid", "Ninja'd the chest")
		local rev = note.rev
		assert.are.equal(note, store:editPlayer(board.id, note.id, " Gankalot ", "avoid", "Ninja'd the chest\n"))
		assert.are.equal(rev, board.notes[note.id].rev)

		local bob = Store.new(db, { now = store.env.now, rand = store.env.rand, me = BOB, prefix = "b1b2c3d4" })
		local edited = assert(bob:editPlayer(board.id, note.id, "Gankalot", "good", "Said sorry and gave it back"))
		assert.is_true(edited.rev > rev)
		assert.are.equal(BOB, edited.editor)
		assert.are.equal(ME, edited.author)
		assert.are.equal("player", edited.kind)
		assert.are.equal("good", Players.entries(board)[1].verdict)
	end)

	it("only edits live player notes", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		local plain = store:addNote(board.id, "Bring flasks")
		local entry = store:addPlayer(board.id, "Gankalot", "avoid", "")
		assert.are.same({ nil, "missing" }, { store:editPlayer(board.id, plain.id, "Bob", "avoid", "") })
		assert.are.same({ nil, "missing" }, { store:editPlayer(board.id, PREFIX .. "-0099", "Bob", "avoid", "") })
		assert.are.same({ nil, "player_name" }, { store:editPlayer(board.id, entry.id, ";", "avoid", "") })
		store:deleteNote(board.id, entry.id)
		assert.are.same({ nil, "deleted" }, { store:editPlayer(board.id, entry.id, "Bob", "avoid", "") })
		assert.are.same({}, Players.entries(board))
	end)
end)

describe("Players.entries, index and lookup", function()
	local function setup()
		local store = newStore()
		local raid = store:createBoard("Raid")
		local guild = store:createBoard("Guild")
		store:addPlayer(raid.id, "Zed", "good", "")
		store:addPlayer(raid.id, "aprune", "good", "Great tank")
		store:addPlayer(raid.id, "Aprune Proudshield", "avoid", "Left mid-pull")
		store:addPlayer(guild.id, "Aprune-OtherRealm", "good", "")
		-- A newer client's verdict and a bad header are skipped, not shown.
		raid.notes[PREFIX .. "-0098"] = { id = PREFIX .. "-0098", author = BOB, created = T0, rev = T0 + 50,
			editor = BOB, text = "P1;caution;Aprune", color = 1, deleted = false, kind = "player" }
		return store, raid, guild
	end

	it("lists a board's entries by name, then newest first", function()
		local _, raid = setup()
		local names = {}
		for _, entry in ipairs(Players.entries(raid)) do
			names[#names + 1] = entry.name .. ":" .. entry.verdict
		end
		assert.are.same({ "aprune:good", "Aprune Proudshield:avoid", "Zed:good" }, names)
	end)

	it("finds a player across boards by any form of their name, avoid entries first", function()
		local store, raid, guild = setup()
		for _, name in ipairs({ "Aprune", "APRUNE Proudshield-Realm", "aprune-x" }) do
			local found = Players.lookup(store:boards(), name)
			assert.are.equal(3, #found, name)
			assert.are.equal("avoid", found[1].verdict)
			assert.are.equal(raid, found[1].board)
			assert.are.same({ "good", "good" }, { found[2].verdict, found[3].verdict })
		end
		local index = Players.index(store:boards())
		assert.are.equal(guild, index.aprune[2].board) -- the newer good entry first
		assert.are.equal(1, #index.zed)
		assert.are.same({}, Players.lookup(store:boards(), "Nobody"))
		assert.are.same({}, Players.lookup(store:boards(), "-"))
	end)
end)

describe("the Players tab's view", function()
	local function entries()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:addPlayer(board.id, "Gankalot", "avoid", "Ninja'd " .. LINK)
		store:addPlayer(board.id, "Mira", "good", "Kind healer")
		store:addPlayer(board.id, "Zed", "avoid", "")
		return Players.entries(board), store, board
	end

	it("builds rows with who noted each and when", function()
		local list = entries()
		local rows = View.playerRows(list, { avoid = true, good = true }, "", T0 + 3600, "Realm")
		assert.are.equal(3, #rows)
		assert.are.same({ index = 1, noteId = list[1].note.id, name = "Gankalot", verdict = "avoid", label = "Avoid",
			reason = "Ninja'd " .. LINK, byline = "Will", age = "59m" }, rows[1])
		assert.are.equal("Good player", rows[2].label)
		assert.are.equal("2 to avoid · 1 good player", View.playerCount(list, 3))
	end)

	it("filters by verdict and by search", function()
		local list = entries()
		local function names(show, query)
			local out = {}
			for _, row in ipairs(View.playerRows(list, show, query, T0, "Realm")) do
				out[#out + 1] = row.name
			end
			return out
		end
		local both = { avoid = true, good = true }
		assert.are.same({ "Gankalot", "Zed" }, names({ avoid = true }, ""))
		assert.are.same({ "Mira" }, names({ good = true }, nil))
		assert.are.same({}, names({}, ""))
		assert.are.same({ "Gankalot" }, names(both, "tidal")) -- the link's text, not its code
		assert.are.same({}, names(both, "hitem"))
		assert.are.same({ "Mira" }, names(both, "GOOD healer"))
		assert.are.same({ "Gankalot", "Mira", "Zed" }, names(both, "will"))
		assert.are.equal("1 shown · 2 to avoid · 1 good player", View.playerCount(list, 1))
	end)

	it("checks the editor's fields, and counts the whole entry's bytes", function()
		assert.are.same({ false, nil }, { View.checkPlayer("", "avoid", "x") })
		assert.are.same({ true }, { View.checkPlayer("Bob", "avoid", "") })
		assert.are.same({ false, Commands.explain("player_name") }, { View.checkPlayer("Bob;", "avoid", "") })
		assert.are.same({ false, Commands.explain("verdict") }, { View.checkPlayer("Bob", nil, "") })
		assert.are.same({ false, Commands.explain("escape") }, { View.checkPlayer("Bob", "good", "|T") })
		assert.are.same({ "17 / 2000", false }, { View.playerCounter("Bob", "good", "Great") })
		assert.are.same({ "18 / 2000", false }, { View.playerCounter("Bob;", "good", "Great") })
		assert.are.same({ "2012 / 2000", true }, { View.playerCounter("Bob", "good", string.rep("x", 2000)) })
	end)

	it("makes tooltip lines: verdict, who and where, and a clipped plain reason", function()
		local _, store, board = entries()
		store:addPlayer(board.id, "Gankalot-Realm", "good", string.rep("é", 100))
		store:addPlayer(board.id, "gankalot", "avoid", "Again\nand again")
		store:addPlayer(board.id, "Gankalot Smith", "good", "")
		local found = Players.lookup({ board }, "Gankalot")
		local lines = View.playerTooltip(found, "Realm")
		assert.are.equal(4, #lines)
		assert.are.same({ left = "Corkboard: Avoid", right = "Will · Raid", color = View.VERDICT_COLORS.avoid,
			reason = "Again and again" }, lines[1])
		assert.are.equal("Ninja'd [Tidal Charm]", lines[2].reason)
		assert.are.equal("Corkboard: Good player", lines[3].left)
		assert.is_nil(lines[3].reason)
		assert.are.same({ left = "and 1 more note", color = { 0.62, 0.62, 0.62 } }, lines[4])
		-- An UTF-8 reason is cut on a character boundary.
		local clipped = View.playerTooltip({ found[4] }, "Realm")[1].reason
		assert.are.equal(string.rep("é", 58) .. "...", clipped)
		assert.are.equal("abc", View.clip("abc", 3))
		assert.are.equal("a...", View.clip("abcdef", 4))
	end)
end)

describe("/cork player", function()
	it("says what every board has on a player", function()
		local store = newStore()
		local raid = store:createBoard("Raid")
		local guild = store:createBoard("Guild")
		store:addPlayer(raid.id, "Gankalot", "good", "Was fine once")
		store:addPlayer(guild.id, "Gankalot-Realm", "avoid", "Ninja'd\n" .. LINK)
		local lines = Commands.run(store, "player gankalot")
		assert.are.equal("gankalot on your boards:", lines[1])
		assert.are.equal("  Gankalot-Realm |cffff2020Avoid|r: Ninja'd " .. LINK .. " |cff808080(Will on Guild, just now)|r",
			lines[2])
		assert.are.equal("  Gankalot |cff19ff19Good player|r: Was fine once |cff808080(Will on Raid, just now)|r",
			lines[3])
		assert.are.equal("  |cff19ff19Good player|r: Was fine once |cff808080(Will on Raid, just now)|r",
			Commands.run(store, "player Gankalot")[3])
	end)

	it("answers when there's nothing, or no name", function()
		local store = newStore()
		store:createBoard("Raid")
		assert.are.same({ "None of your boards have a note about Bob." }, Commands.run(store, "player Bob"))
		assert.are.same({ "Usage: /cork player <name>. Add players on the Players tab in /cork." },
			Commands.run(store, "player"))
	end)
end)

describe("player notes in game", function()
	local function boards(client)
		return client.env.CorkboardDB.global.boards
	end

	local GANK = { name = "Gankalot", guid = "Player-4372-0000GANK" }

	local function party()
		local network = Client.Network.new()
		local clients = {}
		for i, name in ipairs({ "Will", "Bob" }) do
			clients[i] = Client.new({
				network = network,
				name = name,
				guid = "Player-4372-0000000" .. i,
				units = i == 1 and { target = GANK } or nil,
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

	-- Opens the Players tab and Add Player. The name comes from the target.
	local function addPlayer(client, verdict, reason)
		if not client.ns.Main:IsShown() then
			client:slash("/cork")
		end
		client.env.CorkboardFrameTab6:Click()
		client.ns.PlayersTab.Widgets().add:Click()
		local editor = client.ns.PlayerEditor.Widgets()
		editor[verdict]:Click()
		editor.reason:SetText(reason)
		editor.save:Click()
		return client:check()
	end

	it("adds an entry on the Players tab and shows it to other members", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		addPlayer(a, "avoid", "Rolled need on everything")
		local editor = a.ns.PlayerEditor.Widgets()
		assert.is_false(editor.save:IsVisible()) -- the editor closed
		network:advance(10, clients)

		local entries = Players.entries(boards(b)[id])
		assert.are.equal(1, #entries)
		assert.are.same({ "Gankalot", "avoid", "Rolled need on everything" },
			{ entries[1].name, entries[1].verdict, entries[1].reason })
		assert.are.equal(a:fullName(), entries[1].note.author)
		assert.are.same({}, b.ns.Store.notes(boards(b)[id]))

		b:slash("/cork")
		b.env.CorkboardFrameTab6:Click()
		local ui = b.ns.PlayersTab.Widgets()
		assert.are.equal(b.ns.PlayersTab.ABOUT, ui.about.text)
		assert.is_true(ui.about:IsVisible())
		assert.are.equal(1, ui.list.count)
		local row = ui.list.elements[1]
		assert.are.equal("Gankalot  |cffff2020Avoid|r", row.name.text)
		assert.are.equal("Rolled need on everything", row.reason.text)
		assert.are.equal("Will · now", row.byline.text)
		assert.are.equal("1 to avoid · 0 good players", ui.count.text)
		assert.is_function(row:GetScript("OnHyperlinkEnter"))

		-- B changes the verdict from the row's Edit button.
		row:Run("OnEnter")
		row.edit:Click()
		local bEditor = b.ns.PlayerEditor.Widgets()
		assert.are.equal("Gankalot", bEditor.name.text)
		assert.is_true(bEditor.avoid:GetChecked())
		bEditor.good:Click()
		assert.is_false(bEditor.avoid:GetChecked())
		bEditor.reason:SetText("Turned out it was a misclick. Great tank since.")
		bEditor.save:Click()
		network:advance(10, clients)
		local edited = Players.entries(boards(a)[id])[1]
		assert.are.equal("good", edited.verdict)
		assert.are.equal(b:fullName(), edited.note.editor)

		-- The filters and search.
		ui.good:SetChecked(false)
		ui.good:Click()
		assert.are.equal(0, ui.list.count)
		assert.are.equal("No players match.", ui.empty.text)
		ui.good:SetChecked(true)
		ui.good:Click()
		ui.search:SetText("tank")
		assert.are.equal(1, ui.list.count)

		-- And deletes it: gone for both.
		ui.list.elements[1]:Run("OnEnter")
		ui.list.elements[1].delete:Click()
		assert.are.equal("Delete this player note?", b.popup.text)
		b:acceptPopup()
		network:advance(10, clients)
		assert.are.same({}, Players.entries(boards(a)[id]))
		ui.search:SetText("")
		assert.are.equal(0, ui.list.count)
		assert.is_truthy(ui.empty.text:find("No players noted yet", 1, true))
	end)

	it("won't save without a name, and says why a name can't be used", function()
		local _, clients = party()
		local b = clients[2] -- targets nobody
		b:slash("/cork")
		b.env.CorkboardFrameTab6:Click()
		b.ns.PlayersTab.Widgets().add:Click()
		local editor = b.ns.PlayerEditor.Widgets()
		assert.are.equal("", editor.name.text)
		assert.is_true(editor.avoid:GetChecked())
		assert.is_false(editor.save.enabled)
		assert.is_false(editor.delete:IsShown())
		editor.target:Click()
		assert.are.equal("Target a player first.", editor.message.text)
		editor.name:SetText("Bob;x")
		assert.is_false(editor.save.enabled)
		assert.are.equal(Commands.explain("player_name"), editor.message.text)
		editor.name:SetText("Bob")
		assert.is_true(editor.save.enabled)
		assert.are.equal("", editor.message.text)
		assert.are.equal("12 / 2000", editor.counter.text)
	end)

	it("adds the boards' verdicts to a player's tooltip", function()
		local network, clients = party()
		local a, b = clients[1], clients[2]
		addPlayer(a, "avoid", "Rolled need on " .. LINK)
		network:advance(10, clients)
		b.units.mouseover = { name = "Gankalot Smith", realm = "", guid = "Player-4372-0000GANK" }
		local lines = b:hoverUnit("mouseover")
		assert.are.equal(2, #lines)
		assert.are.same({ left = "Corkboard: Avoid", right = "Will · Molten Core prep", r = 1, g = 0.125, b = 0.125 },
			lines[1])
		assert.are.same({ left = "Rolled need on [Tidal Charm]", r = 0.9, g = 0.9, b = 0.9, wrap = true }, lines[2])

		-- Someone else, an NPC, a secret name: nothing added.
		b.units.mouseover = { name = "Mira", guid = "Player-4372-0000MIRA" }
		assert.are.same({}, b:hoverUnit("mouseover"))
		b.units.mouseover = { name = "Gankalot", guid = "Creature-0-1", player = false }
		assert.are.same({}, b:hoverUnit("mouseover"))
		b.units.mouseover = { name = "Gankalot", guid = "Player-4372-0000GANK" }
		b.secrets["Player-4372-0000GANK"] = true
		b.secrets.Gankalot = true
		assert.are.same({}, b:hoverUnit("mouseover"))
		b.secrets = {}

		-- A change to the board shows at once: the index is rebuilt.
		assert.are.equal(2, #b:hoverUnit("mouseover"))
		b:store():deleteNote(b:board().id, Players.entries(b:board())[1].note.id)
		assert.are.same({}, b:hoverUnit("mouseover"))
	end)

	it("warns once when a player to avoid joins the group", function()
		local network, clients = party()
		local a, b = clients[1], clients[2]
		addPlayer(a, "avoid", "Ninja'd the chest")
		a.units.target = { name = "Mira", guid = "Player-4372-0000MIRA" }
		addPlayer(a, "good", "Great healer")
		network:advance(10, clients)

		local function warnings()
			local out = {}
			for _, line in ipairs(b.chat) do
				if line:find("is in your group", 1, true) then
					out[#out + 1] = line
				end
			end
			return out
		end
		local MIRA = { name = "Mira", guid = "Player-4372-0000MIRA" }
		b:setGroup({ party1 = MIRA })
		b:advance(2)
		assert.are.same({}, warnings()) -- a good player isn't worth a warning
		b:setGroup({ party1 = MIRA, party2 = GANK })
		b:setGroup({ party1 = MIRA, party2 = GANK }) -- a burst of roster updates checks once
		b:advance(2)
		assert.are.same({
			"|cffffd100Corkboard:|r Gankalot is in your group. |cffff2020Avoid|r: Ninja'd the chest "
				.. "|cff808080(Will on Molten Core prep, just now)|r",
		}, warnings())
		b:setGroup({ party1 = MIRA, party2 = GANK, party3 = { name = "Zed", guid = "Player-4372-00000ZED" } })
		b:advance(2)
		assert.are.equal(1, #warnings())

		-- Leaving the group resets it; a raid with them warns again.
		b:setGroup(nil)
		b:advance(2)
		b:setGroup({ raid1 = { name = "Bob", guid = b.guid }, raid2 = GANK })
		b:advance(2)
		assert.are.equal(2, #warnings())
	end)

	it("keeps entries across a /reload", function()
		local network, clients, id = party()
		local a = clients[1]
		addPlayer(a, "good", "Carried us through Deadmines")
		a = a:reload()
		clients[1] = a
		network:advance(10, clients)
		local entries = Players.entries(boards(a)[id])
		assert.are.equal(1, #entries)
		assert.are.equal("Carried us through Deadmines", entries[1].reason)
		assert.are.equal(2, #a:hoverUnit("target"))
	end)
end)
