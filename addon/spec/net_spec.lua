-- Corkboard talking to itself: two or three fake clients, each running the
-- real addon (TOC, libraries, ChatThrottleLib, the transport in Net.lua), on
-- one fake network with password-protected channels and the server throttle.
-- The Phase 2 and Phase 4 acceptance checks that can run outside the game.

local Client = require("helpers.client")

local LINK = "|cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r"

local function has(output, text)
	assert(output:find(text, 1, true), ("expected %q in:\n%s"):format(text, output))
end

local function store(client)
	return client.ns.Corkboard.store
end

local function boards(client)
	return client.env.CorkboardDB.global.boards
end

-- Clients on one network, logged in and past the channel-join delay.
local function party(specs)
	local network = Client.Network.new()
	local clients = {}
	for i, spec in ipairs(specs) do
		clients[i] = Client.new({
			network = network,
			name = spec.name,
			realm = spec.realm,
			guid = "Player-4372-0000000" .. i,
			guild = spec.guild,
			class = spec.class,
		}):login()
	end
	network:advance(10, clients)
	return network, clients
end

local function run(network, clients, seconds)
	network:advance(seconds, clients)
end

-- Runs until check() holds, up to `limit` seconds. Returns the seconds taken.
local function within(network, clients, limit, check)
	local t = 0
	while t <= limit do
		if check() then
			return t
		end
		network:advance(0.25, clients)
		t = t + 0.25
	end
end

local function invite(client)
	return (client:slash("/cork invite"):match("(CORK1:%S+)"))
end

-- A board made by the first client and joined by the rest, synced.
local function shared(specs)
	local network, clients = party(specs)
	local a = clients[1]
	a:createBoard("Molten Core prep")
	local code = invite(a)
	for i = 2, #clients do
		if not specs[i].outside then
			has(clients[i]:slash("/cork join " .. code), "Joined")
		end
	end
	local id = store(a):current().id
	assert(within(network, clients, 30, function()
		for i = 2, #clients do
			local b = not specs[i].outside and boards(clients[i])[id]
			if specs[i].outside then
				b = { meta = { name = "Molten Core prep" } }
			end
			if not (b and b.meta and b.meta.name == "Molten Core prep") then
				return false
			end
		end
		return true
	end), "the board name never arrived")
	return network, clients, id
end

describe("Corkboard between fake clients (Phase 2) #slow", function()
	it("round-trips an invite, and a joiner gets the board", function()
		local network, clients, id = shared({ { name = "Will" }, { name = "Bob" } })
		local a, b = clients[1], clients[2]
		a:addNote("Need 4x " .. LINK)
		run(network, clients, 5)
		assert.are.same({ "Need 4x " .. LINK, 1 }, { b:noteTexts() })
		has(b:slash("/cork members"), "Will-MirageRaceway")
		assert(within(network, clients, 30, function()
			return boards(a)[id].members["Bob-MirageRaceway"] ~= nil
		end))
		has(a:slash("/cork members"), "2 members")
	end)

	-- Forever 1.60.1: UnitFullName("player") gave the surname as the realm, so
	-- the addon called itself "Aprune-Proudshield", saw its own echo as
	-- another member and showed "Synced with Aprune Proudshield-…".
	it("names a player with a surname the way other members see them", function()
		local network, clients, id = shared({ { name = "Aprune Proudshield" }, { name = "Bob" } })
		local a, b = clients[1], clients[2]
		local me = "Aprune Proudshield-MirageRaceway"
		assert.are.equal(me, store(a).env.me)
		a:addNote("hello")
		run(network, clients, 60)
		assert.are.equal(me, boards(b)[id].notes[next(boards(b)[id].notes)].author)
		assert.are.equal(me, boards(b)[id].owner)
		local names = {}
		for name in pairs(boards(a)[id].members) do
			names[#names + 1] = name
		end
		table.sort(names)
		assert.are.same({ me, "Bob-MirageRaceway" }, names)
	end)

	it("an edit appears on the other client within 5 s", function()
		local network, clients, id = shared({ { name = "Will" }, { name = "Bob" } })
		local a, b = clients[1], clients[2]
		a:addNote("Bring fire resistance")
		assert.is_truthy(within(network, clients, 5, function()
			return b:noteTexts() == "Bring fire resistance"
		end))
		b:editNote(1, { text = "Bring fire resistance gear" })
		assert.is_truthy(within(network, clients, 5, function()
			return a:noteTexts() == "Bring fire resistance gear"
		end))
		a:deleteNote(1)
		assert.is_truthy(within(network, clients, 5, function()
			return b:noteTexts() == ""
		end))
		assert.are.equal(boards(a)[id].clock, boards(b)[id].clock)
	end)

	it("keeps the hidden channel out of every chat frame", function()
		local _, clients, id = shared({ { name = "Will" }, { name = "Bob" } })
		for _, client in ipairs(clients) do
			local name = client.ns.Store.channelName(boards(client)[id])
			assert.is_truthy(client:channelNumber(name), "not in the channel")
			assert.is_nil(client.chatChannels[name:lower()])
			for _, line in ipairs(client.chat) do
				assert.is_nil(line:find(name, 1, true), "chat showed: " .. line)
			end
		end
	end)

	it("ignores traffic from outside the board, and drops secret payloads", function()
		local network, clients, id = shared({ { name = "Will", guild = "G" }, { name = "Bob", guild = "G" },
			{ name = "Eve", guild = "G", outside = true } })
		local a, b, eve = clients[1], clients[2], clients[3]
		-- Eve isn't on the board: she can't hear it, and what she says on GUILD
		-- about it is ignored (it isn't a guild board).
		local board = boards(a)[id]
		local wire = eve.ns.Corkboard.wire
		local text = wire:encode({ v = 1, t = "PUT", b = id, n = { { id = "a1b2c3d4-0001", author = "Eve-MirageRaceway",
			created = 1790000000, rev = 1790009999, editor = "Eve-MirageRaceway", text = "spam", color = 1,
			deleted = false } } })
		eve.env.C_ChatInfo.RegisterAddonMessagePrefix("CORK")
		for _, chunk in ipairs(eve.ns.Wire.split(text)) do
			eve.env.C_ChatInfo.SendAddonMessage("CORK", chunk, "GUILD")
		end
		run(network, clients, 3)
		assert.is_nil(board.notes["a1b2c3d4-0001"])
		assert.is_true(a.ns.Net.stats.ignored >= 1)
		-- A secret payload is dropped before anything reads it.
		local secret = "\1\1secret"
		b.secrets[secret] = true
		b.fire("CHAT_MSG_ADDON", "CORK", secret, "CHANNEL", "Will", "", 0, 5, "", 0)
		b:check()
		assert.are.equal(1, b.ns.Net.stats.secret)
		b.secrets.CORK = true
		b.fire("CHAT_MSG_ADDON", "CORK", "\1\1x", "CHANNEL", "Will", "", 0, 5, "", 0)
		assert.are.equal(2, b.ns.Net.stats.secret)
		assert.is_nil(boards(eve)[id])
	end)

	it("keeps syncing across a /reload", function()
		local network, clients, id = shared({ { name = "Will" }, { name = "Bob" } })
		clients[2] = clients[2]:reload()
		run(network, clients, 10)
		clients[1]:addNote("after the reload")
		assert.is_truthy(within(network, clients, 5, function()
			return clients[2]:noteTexts() == "after the reload"
		end))
		assert.is_truthy(boards(clients[2])[id])
	end)

	it("syncs a guild board over GUILD, without a channel", function()
		local network, clients, id = shared({ { name = "Will", guild = "G" }, { name = "Bob", guild = "G" } })
		for _, client in ipairs(clients) do
			client:slash("/cork guild on")
		end
		run(network, clients, 35)
		for _, client in ipairs(clients) do
			local name = client.ns.Store.channelName(boards(client)[id])
			assert.is_nil(client:channelNumber(name), "still in the channel")
		end
		clients[1]:addNote("over guild chat")
		assert.is_truthy(within(network, clients, 5, function()
			return clients[2]:noteTexts() == "over guild chat"
		end))
		local guildSends = 0
		for _, sent in ipairs(clients[1].sentAddon) do
			if sent.chatType == "GUILD" then
				guildSends = guildSends + 1
			end
		end
		assert.is_true(guildSends > 0)
	end)
end)

describe("Corkboard between fake clients (Phase 4) #slow", function()
	it("queues edits during an encounter and delivers them within 10 s of it ending", function()
		local network, clients, id = shared({ { name = "Will" }, { name = "Bob" } })
		local a, b = clients[1], clients[2]
		a.locked = true
		for i = 1, 3 do
			a:addNote("pull " .. i)
		end
		run(network, clients, 20)
		assert.are.equal("", b:noteTexts())
		assert.is_false(a.ns.Corkboard.outbox.gate.open)
		a.locked = false
		assert.is_truthy(within(network, clients, 10, function()
			return select(2, b:noteTexts()) == 3
		end))
		assert.are.equal(3, #store(b).notes(boards(b)[id]))
	end)

	it("loses nothing to the throttle: 60 quick notes all arrive", function()
		local network, clients, id = shared({ { name = "Will" }, { name = "Bob" } })
		local a, b = clients[1], clients[2]
		for i = 1, 60 do
			a:addNote(("note number %d with a little text to fill it out"):format(i))
		end
		assert.is_truthy(within(network, clients, 180, function()
			return #store(b).notes(boards(b)[id]) == 60
		end))
		local stats = a.ns.Corkboard.outbox.stats
		assert.are.equal(0, stats.errors)
		assert.are.equal(0, stats.dropped)
	end)

	it("stays quiet in chat and error-free through a sync", function()
		local network, clients = shared({ { name = "Will" }, { name = "Bob" }, { name = "Cara" } })
		for i = 1, 5 do
			clients[1 + i % 3]:addNote("chatter " .. i)
		end
		run(network, clients, 30)
		for _, client in ipairs(clients) do
			client:check()
			assert.are.equal(0, client.ns.Corkboard.sync.stats.malformed)
		end
	end)
end)

describe("the Members tab and sharing UI #slow", function()
	local function buttonNamed(client, label)
		for _, frame in ipairs(client.frames) do
			if frame.kind == "Button" and frame.text == label and frame:IsVisible() then
				return frame
			end
		end
		error("no visible button " .. label)
	end

	local function tab(client, i)
		return client.env["CorkboardFrameTab" .. i]
	end

	it("shows the invite and roster, and removes a member", function()
		local network, clients, id = shared({ { name = "Will" }, { name = "Bob", class = "PRIEST" } })
		local a, b = clients[1], clients[2]
		run(network, clients, 20)
		a:slash("/cork")
		tab(a, 2):Click()
		local members = a.ns.Members.Widgets()
		-- The panel sits in the note area's inset, not over the whole window.
		assert.are.equal("InsetFrameTemplate", members.list:GetParent():GetParent().template)
		assert.are.equal(a.ns.Invite.encode(boards(a)[id]), members.invite.text)
		assert.is_true(members.cloud:GetChecked())
		local rows = {}
		for _, row in ipairs(members.list.elements) do
			if row:IsVisible() then
				rows[#rows + 1] = row
			end
		end
		assert.are.equal(2, #rows)
		assert.are.equal("Will", rows[1].cells[1].text)
		assert.are.equal("Bob", rows[2].cells[1].text)
		assert.are.equal("20", rows[1].cells[3].text)
		assert.are.equal("20", rows[2].cells[3].text)
		assert.are.equal("Online", rows[2].cells[4].text)
		-- A level-up reaches the other members' roster straight away.
		b.level = 21
		b.fire("PLAYER_LEVEL_UP", 21)
		assert(within(network, clients, 10, function()
			return rows[2].cells[3].text == "21"
		end), "Bob's new level never showed")
		assert.is_true(rows[2].remove:IsShown())
		assert.is_false(rows[1].remove:IsShown())
		-- Typing in the invite box puts the invite back.
		members.invite:Insert("junk")
		members.invite:Run("OnTextChanged", true)
		assert.are.equal(a.ns.Invite.encode(boards(a)[id]), members.invite.text)
		local secret = boards(a)[id].secret
		rows[2].remove:Click()
		has(a.popup.text, "Remove Bob from Molten Core prep?")
		a:acceptPopup()
		assert.is_true(boards(a)[id].members["Bob-MirageRaceway"].removed)
		assert.are_not.equal(secret, boards(a)[id].secret)
		members.cloud:SetChecked(false)
		members.cloud:Click()
		assert.is_false(boards(a)[id].cloud)
		tab(a, 1):Click()
		assert.is_false(members.list:IsVisible())
	end)

	it("joins from the Join button", function()
		local network, clients = party({ { name = "Will" }, { name = "Bob" } })
		local a, b = clients[1], clients[2]
		a:createBoard("Raid")
		local code = invite(a)
		b:slash("/cork")
		buttonNamed(b, "Join"):Click()
		b:typeInPopup("not an invite")
		assert.is_table(b.popup) -- stays open with a warning
		has(b.chat[#b.chat], "isn't a Corkboard invite")
		b:typeInPopup(code)
		assert.is_nil(b.popup)
		assert(within(network, clients, 30, function()
			local current = store(b):current()
			return current and current.meta and current.meta.name == "Raid"
		end))
	end)

	it("opens the debug panel", function()
		local network, clients = shared({ { name = "Will" }, { name = "Bob" } })
		local a = clients[1]
		a:slash("/cork debug")
		run(network, clients, 2)
		local debug = a.env.CorkboardDebug
		assert.is_true(debug:IsShown())
		buttonNamed(a, "Force HELLO"):Click()
		run(network, clients, 2)
		a:slash("/cork debug")
		assert.is_false(debug:IsShown())
		has(a:slash("/cork sync"), "Asking members")
	end)

	it("shows the sync state in the status line", function()
		local network, clients = shared({ { name = "Will" }, { name = "Bob" } })
		local a = clients[1]
		a:slash("/cork")
		run(network, clients, 400)
		local status
		for _, fs in ipairs(a.env.CorkboardFrame.fontStrings) do
			if fs.text:find("^Synced with") or fs.text:find("online$") then
				status = fs.text
			end
		end
		assert.is_truthy(status, "no sync status shown")
	end)
end)
