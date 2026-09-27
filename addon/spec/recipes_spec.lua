-- The Professions tab (docs/design.md §9.2): recipe lists as "recipes"-kind
-- notes, their encoding, sharing rules, search, and two clients in game.

local Recipes = require("Core.Recipes")
local Store = require("Core.Store")
local Sanitise = require("Core.Sanitise")
local Sync = require("Core.Sync")
local Invite = require("Core.Invite")
local Sim = require("helpers.sim")
local Client = require("helpers.client")

local T0 = 1790000000
local ME = "Will-Realm"
local PREFIX = "a1b2c3d4"
-- As Forever 1.60.1 reported it (§2).
local LW = { id = 165, name = "Leatherworking", skill = 47, max = 75 }
local SEWING = 1263079

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

-- Recipes.encode's text alone (it also returns how many ids it holds).
local function encoded(profession, ids)
	return (Recipes.encode(profession, ids))
end

local function short(name)
	return (name:match("^([^%-]+)"))
end

describe("Recipes.encode and decode", function()
	it("round-trips a profession, sorted, without duplicates or bad ids", function()
		local text, shown = Recipes.encode(LW, { SEWING + 5, SEWING, 7, SEWING, 0, -1, 1.5, "x", SEWING + 1 })
		assert.are.equal(4, shown)
		assert.are.equal("R1;165;47;75;4;Leatherworking\n7,r2lc,1,4", text)
		assert.is_true(Sanitise.text(text))
		assert.are.same({
			id = 165,
			name = "Leatherworking",
			skill = 47,
			max = 75,
			learned = 4,
			recipes = { 7, SEWING, SEWING + 1, SEWING + 5 },
		}, Recipes.decode(text))
	end)

	it("writes a profession with no recipes as its header alone", function()
		local text, shown = Recipes.encode({ id = 185, name = "Cooking" }, {})
		assert.are.equal("R1;185;0;0;0;Cooking", text)
		assert.are.equal(0, shown)
		assert.are.same({ id = 185, name = "Cooking", skill = 0, max = 0, learned = 0, recipes = {} },
			Recipes.decode(text))
	end)

	it("handles the largest ids", function()
		local text = Recipes.encode(LW, { Recipes.MAX_ID, 1 })
		assert.are.same({ 1, Recipes.MAX_ID }, Recipes.decode(text).recipes)
	end)

	it("keeps the lowest ids that fit in a note, and counts them all", function()
		local ids = {}
		for i = 1, 1200 do
			ids[i] = i * 1000 -- gaps of "rs": 3 bytes each with the comma
		end
		local text, shown = Recipes.encode(LW, ids)
		assert.is_true(#text <= Sanitise.MAX_TEXT)
		assert.is_true(shown > 500 and shown < 1200, shown)
		local entry = Recipes.decode(text)
		assert.are.equal(1200, entry.learned)
		assert.are.equal(shown, #entry.recipes)
		assert.are.equal(shown * 1000, entry.recipes[shown])
		assert.is_true(Sanitise.text(text))
	end)

	it("refuses a profession it can't write", function()
		for _, profession in ipairs({
			"Leatherworking",
			{ id = 0, name = "Leatherworking" },
			{ id = 1.5, name = "Leatherworking" },
			{ id = 165, name = "" },
			{ id = 165, name = "Leather;working" },
			{ id = 165, name = "Leather|working" },
			{ id = 165, name = "Leather\nworking" },
			{ id = 165, name = ("x"):rep(65) },
			{ id = 165, name = "\255" },
			{ id = 165, name = "Leatherworking", skill = -1 },
			{ id = 165, name = "Leatherworking", max = 10000 },
		}) do
			assert.are.same({ nil, "profession" }, { Recipes.encode(profession, { 1 }) })
		end
	end)

	it("ignores text that isn't a recipe list", function()
		for _, text in ipairs({
			42,
			"",
			"Bring flasks",
			"R2;165;47;75;1;Leatherworking\n1",
			"R1;165;47;75;1;\n1",
			"R1;165;47;75;1;Leather;working\n1",
			"R1;0;47;75;1;Leatherworking\n1",
			"R1;12345678901;47;75;1;Leatherworking\n1",
			"R1;165;47;75;1;Leatherworking\n",
			"R1;165;47;75;2;Leatherworking\n1,,2",
			"R1;165;47;75;2;Leatherworking\n,1",
			"R1;165;47;75;2;Leatherworking\n1,",
			"R1;165;47;75;1;Leatherworking\nA",
			"R1;165;47;75;2;Leatherworking\n1,0",
			"R1;165;47;75;1;Leatherworking\n1000000",
			"R1;165;47;75;2;Leatherworking\nzik0zj,1",
			"R1;165;47;75;1;Leatherworking\n1,2",
			"R1;165;47;75;99999999999;Leatherworking",
		}) do
			assert.is_nil(Recipes.decode(text), tostring(text))
		end
	end)

	it("builds the client's recipe link, whatever the name", function()
		assert.are.equal("|cffffd000|Henchant:1263079|h[Sewing Machine]|h|r", Recipes.link(SEWING, "Sewing Machine"))
		assert.are.equal("|cffffd000|Henchant:7|h[Recipe 7]|h|r", Recipes.link(7, nil))
		assert.are.equal("|cffffd000|Henchant:7|h[Recipe 7]|h|r", Recipes.link(7, "|[]"))
		assert.are.equal("|cffffd000|Henchant:7|h[Bad Tthing]|h|r", Recipes.link(7, "Bad |Tthing"))
		assert.is_true(Sanitise.text(Recipes.link(7, "|Tx|t[y]")))
	end)
end)

describe("Recipes.lists and rows", function()
	local function note(id, author, rev, text, fields)
		local n = { id = id, author = author, created = T0, rev = rev, editor = author, text = text, color = 1,
			deleted = false, kind = "recipes" }
		for k, v in pairs(fields or {}) do
			n[k] = v
		end
		return n
	end

	local function board(notes)
		local b = { notes = {} }
		for _, n in ipairs(notes) do
			b.notes[n.id] = n
		end
		return b
	end

	local names =
		{ [1] = "Light Armor Kit", [2] = "Handstitched Boots", [SEWING] = "Sewing Machine", [3] = "Herb Baked Egg" }
	local function nameOf(id)
		return names[id]
	end

	local cork = board({
		note("a1b2c3d4-0001", "Will-Realm", T0 + 1, encoded(LW, { 1, 2 })),
		-- Will's newer copy of the same profession wins.
		note("a1b2c3d4-0002", "Will-Realm", T0 + 5, encoded(LW, { 1, 2, SEWING })),
		note("b1b2c3d4-0001", "Bob-Realm", T0 + 2, encoded(LW, { 2 })),
		note("b1b2c3d4-0002", "Bob-Realm", T0 + 3, encoded({ id = 185, name = "Cooking", skill = 10, max = 75 },
			{ 3, 4 })),
		-- Ignored: deleted, another kind, and a list that doesn't parse.
		note("c1b2c3d4-0001", "Amy-Realm", T0 + 9, "", { deleted = true }),
		note("c1b2c3d4-0002", "Amy-Realm", T0 + 9, encoded(LW, { 1 }), { kind = "gear" }),
		note("c1b2c3d4-0003", "Amy-Realm", T0 + 9, "R1;165;1;75;1;Leatherworking\nzz,"),
	})

	it("keeps the newest list per character and profession, by profession then name", function()
		local lists = Recipes.lists(cork)
		local got = {}
		for i, item in ipairs(lists) do
			got[i] = item.author .. " " .. item.profession.name .. " " .. #item.profession.recipes
		end
		assert.are.same({ "Bob-Realm Cooking 2", "Bob-Realm Leatherworking 1", "Will-Realm Leatherworking 3" }, got)
		assert.are.equal("a1b2c3d4-0002", lists[3].note.id)
	end)

	it("lists professions when there's no search", function()
		local rows, cut = Recipes.rows(Recipes.lists(cork), "  ", nameOf, short)
		assert.is_false(cut)
		assert.are.same({
			{ index = 1, text = "Cooking 10/75 · 2 recipes", who = "Bob", key = "Bob-Realm\n185", open = false,
				empty = false },
			{ index = 2, text = "Leatherworking 47/75 · 1 recipe", who = "Bob", key = "Bob-Realm\n165", open = false,
				empty = false },
			{ index = 3, text = "Leatherworking 47/75 · 3 recipes", who = "Will", key = ME .. "\n165", open = false,
				empty = false },
		}, rows)
	end)

	it("lists an opened profession's recipes under it, sorted by name", function()
		local rows, cut = Recipes.rows(Recipes.lists(cork), "", nameOf, short, { [ME .. "\n165"] = true })
		assert.is_false(cut)
		local got = {}
		for i, row in ipairs(rows) do
			assert.are.equal(i, row.index)
			got[i] = { row.text, row.who, row.key or false, row.open or false, row.nested or false }
		end
		assert.are.same({
			{ "Cooking 10/75 · 2 recipes", "Bob", "Bob-Realm\n185", false, false },
			{ "Leatherworking 47/75 · 1 recipe", "Bob", "Bob-Realm\n165", false, false },
			{ "Leatherworking 47/75 · 3 recipes", "Will", ME .. "\n165", true, false },
			{ Recipes.link(2, "Handstitched Boots"), "", false, false, true },
			{ Recipes.link(1, "Light Armor Kit"), "", false, false, true },
			{ Recipes.link(SEWING, "Sewing Machine"), "", false, false, true },
		}, got)
		-- A search shows its own results, whatever is open.
		local found = Recipes.rows(Recipes.lists(cork), "boots", nameOf, short, { [ME .. "\n165"] = true })
		assert.are.equal(1, #found)
		assert.is_nil(found[1].key)
	end)

	it("marks a profession with no recipes listed", function()
		local rows = Recipes.rows(Recipes.lists(board({ note("a1b2c3d4-0001", ME, T0, "R1;356;20;75;0;Fishing") })), "",
			nameOf, short, { [ME .. "\n356"] = true })
		assert.are.equal(1, #rows)
		assert.is_true(rows[1].empty)
		assert.is_true(rows[1].open)
	end)

	it("says when a list holds only some of the recipes", function()
		local text = "R1;165;47;75;9;Leatherworking\n1,1"
		local rows = Recipes.rows(Recipes.lists(board({ note("a1b2c3d4-0001", ME, T0, text) })), "", nameOf, short)
		assert.are.equal("Leatherworking 47/75 · 2 of 9 recipes", rows[1].text)
	end)

	it("finds recipes by name, with everyone who knows them", function()
		local rows = Recipes.rows(Recipes.lists(cork), "BOOTS", nameOf, short)
		assert.are.same({ { index = 1, text = Recipes.link(2, "Handstitched Boots"), who = "Bob, Will", recipe = true } },
			rows)
	end)

	it("finds a member's or a profession's recipes, sorted by name", function()
		local byMember = Recipes.rows(Recipes.lists(cork), "will", nameOf, short)
		assert.are.same({ Recipes.link(2, "Handstitched Boots"), Recipes.link(1, "Light Armor Kit"),
			Recipes.link(SEWING, "Sewing Machine") }, { byMember[1].text, byMember[2].text, byMember[3].text })
		local byProfession = Recipes.rows(Recipes.lists(cork), "cooking", nameOf, short)
		-- Recipe 4 has no name on this client: it sorts first and still shows.
		assert.are.same({ Recipes.link(4), Recipes.link(3, "Herb Baked Egg") },
			{ byProfession[1].text, byProfession[2].text })
		assert.are.same({}, (Recipes.rows(Recipes.lists(cork), "boots amy", nameOf, short)))
	end)

	it("caps the rows at Recipes.SHOWN", function()
		local ids = {}
		for i = 1, Recipes.SHOWN + 5 do
			ids[i] = i
		end
		local big = board({ note("a1b2c3d4-0001", ME, T0, encoded(LW, ids)) })
		local rows, cut = Recipes.rows(Recipes.lists(big), "leather", function()
			return nil
		end, short)
		assert.are.equal(Recipes.SHOWN, #rows)
		assert.is_true(cut)
	end)
end)

describe("Store recipe sharing", function()
	local function mine(board)
		local lists = {}
		for _, item in ipairs(Recipes.lists(board)) do
			if item.author == ME then
				lists[#lists + 1] = item
			end
		end
		return lists
	end

	it("shares a scan to every board with the option on, and keeps it", function()
		local store, db = newStore()
		local a = store:createBoard("Raid")
		local b = store:createBoard("Guild")
		assert.are.equal(2, store:learned(LW, { SEWING, 1 }))
		for _, board in ipairs({ a, b }) do
			local lists = mine(board)
			assert.are.equal(1, #lists)
			assert.are.same({ 1, SEWING }, lists[1].profession.recipes)
			assert.are.equal("recipes", lists[1].note.kind)
		end
		assert.are.equal(Recipes.encode(LW, { 1, SEWING }), db.char.professions[165])
		-- Recipe lists stay off the Notes and Gear tabs.
		assert.are.same({}, Store.notes(a))
		assert.are.same({}, Store.gear(a))
	end)

	it("edits its entry when the scan changes, and does nothing when it doesn't", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:learned(LW, { 1 })
		local id = mine(board)[1].note.id
		assert.are.equal(0, store:learned(LW, { 1 }))
		assert.are.equal(1, store:learned({ id = 165, name = "Leatherworking", skill = 50, max = 75 }, { 1, 2 }))
		local lists = mine(board)
		assert.are.equal(1, #lists)
		assert.are.equal(id, lists[1].note.id)
		assert.are.equal(50, lists[1].profession.skill)
		-- A second profession gets its own entry.
		assert.are.equal(1, store:learned({ id = 185, name = "Cooking", skill = 1, max = 75 }, { 3 }))
		assert.are.equal(2, #mine(board))
	end)

	it("deletes extra copies of a profession, such as one from a second install", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:learned(LW, { 1 })
		local copy = mine(board)[1].note
		board.notes["a1b2c3d4-0099"] = {
			id = "a1b2c3d4-0099", author = ME, created = copy.created, rev = copy.rev - 1, editor = ME,
			text = copy.text, color = 1, deleted = false, kind = "recipes",
		}
		assert.are.equal(1, store:shareRecipes())
		assert.is_true(board.notes["a1b2c3d4-0099"].deleted)
		assert.is_false(copy.deleted)
	end)

	it("skips boards with the option off, boards that removed the player, and joined boards not yet synced", function()
		local store = newStore()
		local off = store:createBoard("Quiet")
		local gone = store:createBoard("Old guild")
		store:setOption(off.id, "recipes", false)
		gone.members[ME].removed = true
		local joined = assert(store:joinBoard(Invite.encode({ id = "k3f9x2m7q1pz8c4w", secret = ("s"):rep(24),
			owner = "Bob-Realm" })))
		assert.is_true(joined.recipes)
		assert.are.equal(0, store:learned(LW, { 1 }))
		assert.are.same({}, mine(off))
		assert.are.same({}, mine(gone))
		assert.are.same({}, mine(joined))
		-- Once it matches a peer's copy, the kept scan goes up.
		joined.sync.lastPeerAt = T0
		assert.are.equal(1, store:shareRecipes(joined.id))
		assert.are.equal(1, #mine(joined))
	end)

	it("takes the lists down when sharing is turned off, and back up when it's on", function()
		local store = newStore()
		local board = store:createBoard("Raid")
		store:learned(LW, { 1 })
		store:learned({ id = 185, name = "Cooking", skill = 1, max = 75 }, { 3 })
		-- Someone else's list stays.
		local bob = { id = "b1b2c3d4-0001", author = "Bob-Realm", created = T0, rev = T0, editor = "Bob-Realm",
			text = Recipes.encode(LW, { 2 }), color = 1, deleted = false, kind = "recipes" }
		board.notes[bob.id] = bob
		assert.are.equal(board, store:setRecipeSharing(board.id, false))
		assert.is_false(board.recipes)
		assert.are.same({}, mine(board))
		assert.is_false(bob.deleted)
		store:learned(LW, { 1, 2 }) -- kept, not shared here
		assert.are.same({}, mine(board))
		store:setRecipeSharing(board.id, true)
		assert.are.equal(2, #mine(board))
		assert.are.same({ nil, "missing" }, { store:setRecipeSharing("nope", true) })
	end)

	it("waits for the player's name, and refuses a scan it can't write", function()
		local store, db, env = newStore()
		store:createBoard("Raid")
		assert.are.equal(0, store:shareRecipes())
		env.me = nil
		assert.are.same({ nil, "identity" }, { store:learned(LW, { 1 }) })
		assert.are.same({ nil, "identity" }, { store:shareRecipes() })
		assert.is_nil(db.char.professions)
		env.me = ME
		assert.are.same({ nil, "profession" }, { store:learned({ id = 165, name = "" }, { 1 }) })
		assert.is_nil(db.char.professions)
	end)
end)

describe("the bulk rule with recipe lists", function()
	it("prices a note by its text when that's longer than NOTE_BYTES", function()
		assert.are.equal(Sync.NOTE_BYTES, Sync.noteBytes({ text = "short" }))
		assert.are.equal(1900, Sync.noteBytes({ text = ("x"):rep(1900) }))
		assert.are.equal(Sync.NOTE_BYTES, Sync.noteBytes({}))
	end)

	it("sends a cloud-enabled joiner a partial IDX for a few large notes", function()
		local sim = Sim.new({ seed = 3 })
		local a = sim:add("Will")
		local board = assert(a.store:createBoard("Crafters"))
		for i = 1, 6 do
			-- 6 notes at 150 bytes would be P2P; at their real size they're bulk.
			a.store:addNote(board.id, ("%d "):format(i) .. ("recipe "):rep(250))
		end
		sim:run(5)
		local b = sim:add("Bob")
		sim:logout(b)
		local joined = b.store:joinBoard(Invite.encode(Sim.board(a, board.id)))
		joined.sync.lastCloudAt = sim:serverTime()
		local start = sim.time
		sim:login(b)
		sim:run(60)
		local idx = sim:sent("IDX", start)
		assert.is_true(#idx >= 1)
		assert.are.equal(1, idx[1].envelope.p)
	end)
end)

describe("the Professions tab in game", function()
	local RECIPES = {
		[SEWING] = { learned = true, name = "Sewing Machine" },
		[2149] = { learned = true, name = "Handstitched Leather Boots" },
		[2881] = { learned = false, name = "Light Leather" },
		[9] = { learned = true, isDummyRecipe = true, name = "Dummy" },
	}
	local NAMES = { [SEWING] = "Sewing Machine", [2149] = "Handstitched Leather Boots" }

	local function boards(client)
		return client.env.CorkboardDB.global.boards
	end

	local function copy(t)
		local out = {}
		for k, v in pairs(t) do
			out[k] = type(v) == "table" and copy(v) or v
		end
		return out
	end

	local function lw()
		return { professionID = 165, professionName = "Leatherworking", skillLevel = 47, maxSkillLevel = 75 }
	end

	local function party()
		local network = Client.Network.new()
		local clients = {}
		for i, name in ipairs({ "Will", "Bob" }) do
			clients[i] = Client.new({ network = network, name = name, guid = "Player-4372-0000000" .. i,
				spellNames = NAMES }):login()
		end
		network:advance(10, clients)
		local a, b = clients[1], clients[2]
		a:createBoard("Crafters")
		local code = a:slash("/cork invite"):match("(CORK1:%S+)")
		b:slash("/cork join " .. code)
		network:advance(30, clients)
		return network, clients, a.ns.Corkboard.store:current().id
	end

	local function lists(client, id)
		return Recipes.lists(boards(client)[id])
	end

	it("shares the learned recipes of an open window with other members", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:openProfession(lw(), copy(RECIPES))
		network:advance(10, clients)
		local got = lists(b, id)
		assert.are.equal(1, #got)
		assert.are.equal("Will-MirageRaceway", got[1].author)
		assert.are.same({ 2149, SEWING }, got[1].profession.recipes)
		assert.are.same({}, b.ns.Store.notes(boards(b)[id]))

		-- B's Professions tab lists it, and finds the recipe with a working link.
		b:slash("/cork")
		b.env.CorkboardFrameTab4:Click()
		local ui = b.ns.Professions.Widgets()
		assert.is_true(ui.share:GetChecked())
		local row = ui.list.elements[1]
		assert.is_true(row:IsVisible())
		assert.are.equal("Leatherworking 47/75 · 2 recipes", row.text.text)
		assert.are.equal("Will", row.who.text)
		assert.are.equal("Click a profession to see its recipes.", ui.more.text)

		-- Clicking the profession lists what Will can make, as live links;
		-- clicking again closes it.
		row:Click()
		assert.are.equal(3, ui.list.count)
		assert.are.equal(Recipes.link(2149, "Handstitched Leather Boots"), ui.list.elements[2].text.text)
		assert.are.equal(Recipes.link(SEWING, "Sewing Machine"), ui.list.elements[3].text.text)
		assert.is_function(ui.list.elements[3]:GetScript("OnHyperlinkClick"))
		ui.list.elements[3]:Click() -- a recipe row: nothing to open or close
		assert.are.equal(3, ui.list.count)
		ui.list.elements[1]:Click()
		assert.are.equal(1, ui.list.count)
		ui.search:SetText("sewing")
		row = ui.list.elements[1]
		assert.are.equal(Recipes.link(SEWING, "Sewing Machine"), row.text.text)
		assert.is_function(row:GetScript("OnHyperlinkEnter"))
		row:GetScript("OnHyperlinkEnter")(row, "enchant:1263079")
		assert.are.equal("enchant:1263079", b.env.GameTooltip.link)
		ui.search:SetText("nothing like this")
		assert.are.equal("No recipes match your search.", ui.empty.text)
		b.env.CorkboardFrameTab1:Click()
		assert.is_false(ui.list:IsVisible())
	end)

	it("resends only when the window opens or a recipe is learned, not on each craft", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:openProfession(lw(), copy(RECIPES))
		network:advance(10, clients)
		local rev = lists(b, id)[1].note.rev
		a:craft(48)
		a:craft(49)
		network:advance(10, clients)
		assert.are.equal(rev, lists(b, id)[1].note.rev)
		a:learnRecipe(2881, { learned = true, name = "Light Leather" })
		network:advance(10, clients)
		local got = lists(b, id)[1].profession
		assert.are.same({ 2149, 2881, SEWING }, got.recipes)
		assert.are.equal(49, got.skill)
		a:closeProfession()
		a:learnRecipe(3000, { learned = true }) -- window closed: nothing to read
		network:advance(10, clients)
		assert.are.equal(3, #lists(b, id)[1].profession.recipes)
	end)

	it("doesn't share someone else's recipes from a linked window", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:openProfession(lw(), copy(RECIPES), true)
		network:advance(10, clients)
		assert.are.same({}, lists(b, id))
		assert.are.same({}, lists(a, id))
	end)

	it("takes the list down with the checkbox, and keeps scans across a /reload", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		a:openProfession(lw(), copy(RECIPES))
		a:closeProfession()
		network:advance(10, clients)
		a:slash("/cork")
		a.env.CorkboardFrameTab4:Click()
		local ui = a.ns.Professions.Widgets()
		ui.share:SetChecked(false)
		ui.share:Click()
		network:advance(10, clients)
		assert.are.same({}, lists(b, id))
		ui.share:SetChecked(true)
		ui.share:Click()
		network:advance(10, clients)
		assert.are.equal(1, #lists(b, id))

		-- After a /reload, a new board gets the kept scan without reopening the window.
		a = a:reload()
		clients[1] = a
		network:advance(10, clients)
		local fresh = a:createBoard("Alts")
		assert.are.equal(1, #Recipes.lists(fresh))
	end)

	it("shares with a board joined later, once it has synced", function()
		local network, clients, id = party()
		local a, b = clients[1], clients[2]
		b:openProfession(lw(), copy(RECIPES))
		b:closeProfession()
		network:advance(10, clients)
		assert.are.equal(1, #lists(a, id))
		-- A makes a second board; B joins it and shares once caught up.
		local other = a:createBoard("Second")
		local code = a:slash("/cork invite"):match("(CORK1:%S+)")
		b:slash("/cork join " .. code)
		network:advance(60, clients)
		assert.are.equal(1, #lists(a, other.id))
		assert.are.equal("Bob-MirageRaceway", lists(a, other.id)[1].author)
	end)
end)
