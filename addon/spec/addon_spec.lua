-- The whole addon, as the client loads it: Corkboard.toc with the vendored
-- libraries, AceDB over CorkboardDB, and /cork through the real slash
-- handler. Persistence is checked through a simulated /reload that writes
-- SavedVariables out as Lua source and loads them into a fresh session.

local Client = require("helpers.client")

local LINK = "|cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r"

local function has(output, text)
	assert(output:find(text, 1, true), ("expected %q in:\n%s"):format(text, output))
end

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
	end
	return f ~= nil
end

describe("Corkboard.toc", function()
	local toc
	setup(function()
		local f = assert(io.open("addon/Corkboard/Corkboard.toc", "rb"))
		toc = f:read("*a")
		f:close()
	end)

	it("targets Forever and saves CorkboardDB", function()
		assert.is_truthy(toc:find("## Interface: 16001\n", 1, true))
		assert.is_truthy(toc:find("## SavedVariables: CorkboardDB\n", 1, true))
	end)

	it("lists only files that exist", function()
		for _, file in ipairs(Client.tocFiles()) do
			assert.is_true(fileExists("addon/Corkboard/" .. file), file)
		end
	end)

	it("loads the libraries, then the merge core in order, then the rest", function()
		local files = Client.tocFiles()
		local core = {}
		local lastLib
		for i, file in ipairs(files) do
			if file:find("^Libs/") then
				lastLib = i
			elseif file:find("^Core/") then
				core[#core + 1] = file
				assert.is_true(lastLib ~= nil and lastLib < i, file .. " loads before a library")
			end
		end
		assert.are.same({
			"Core/Util.lua",
			"Core/Sanitise.lua",
			"Core/Merge.lua",
			"Core/Digest.lua",
			"Core/Store.lua",
			"Core/Commands.lua",
			"Core/View.lua",
		}, core)
		local wrapper
		for i, file in ipairs(files) do
			if file == "Corkboard.lua" then
				wrapper = i
			end
		end
		assert.is_number(wrapper)
		for i = wrapper + 1, #files do
			assert.is_truthy(files[i]:find("^UI/"), files[i] .. " should be UI, after the wrapper")
		end
	end)

	it("loads LibStub first", function()
		assert.are.equal("Libs/LibStub/LibStub.lua", Client.tocFiles()[1])
	end)
end)

describe("Corkboard in a fake client", function()
	it("loads, registers its libraries and logs in without errors", function()
		local client = Client.new():login()
		local LibStub = client.env.LibStub
		for _, lib in ipairs({
			"CallbackHandler-1.0", "AceAddon-3.0", "AceEvent-3.0", "AceTimer-3.0", "AceDB-3.0", "AceConsole-3.0",
			"AceComm-3.0", "LibSerialize", "LibDeflate", "LibDataBroker-1.1",
		}) do
			assert.is_table(LibStub(lib, true), lib)
		end
		local addon = client.ns.Corkboard
		assert.are.equal("Will-MirageRaceway", addon.env.me)
		assert.are.equal("6f97d8db", addon.env.prefix)
		assert.is_table(client.env.CorkboardDB)
	end)

	it("keeps the merge core the same tables the TOC loaded", function()
		local client = Client.new():login()
		for _, name in ipairs({ "Util", "Sanitise", "Merge", "Digest", "Store", "Commands", "View" }) do
			assert.is_table(client.ns[name], name)
		end
	end)

	it("exercises the store through /cork", function()
		local client = Client.new():login()
		has(client:slash("/cork help"), "Commands:")
		has(client:slash("/cork create Molten Core prep"), "|cffffd100Corkboard:|r Created board Molten Core prep")
		has(client:slash("/cork add Need 4x " .. LINK), "Added #1")
		has(client:slash("/cork list"), "#1 Need 4x " .. LINK .. " |cff808080(Will-MirageRaceway, just now)|r")
		has(client:slash("/CORK boards"), "Molten Core prep (current)")
	end)

	it("keeps boards and notes across a /reload", function()
		local client = Client.new():login()
		client:slash("/cork create Molten Core prep")
		client:slash("/cork add Need 4x " .. LINK)
		client:slash("/cork add Bring fire resistance")
		client:slash("/cork add Summon at the stone")
		client:advance(120)
		client:slash("/cork edit 2 Bring fire resistance gear")
		client:slash("/cork color 2 4")
		client:slash("/cork delete 3")
		client:slash("/cork create BWL")
		client:slash("/cork rename BWL prep")
		client:slash("/cork use molten core prep")
		local before = client.env.CorkboardDB.global.boards

		local reloaded = client:reload()
		local after = reloaded.env.CorkboardDB.global.boards
		assert.are.same(before, after)

		local list = reloaded:slash("/cork list")
		has(list, "Molten Core prep: 2 notes")
		has(list, "#1 Need 4x " .. LINK .. " |cff808080(Will-MirageRaceway, 1m ago)|r")
		has(list, "#2 Bring fire resistance gear |cff808080(Will-MirageRaceway, just now, colour 4)|r") -- edited
		has(reloaded:slash("/cork boards"), "BWL prep |cff808080- 0 notes")

		-- Ids keep counting past the tombstone that survived the reload.
		has(reloaded:slash("/cork add After the reload"), "Added #4")
	end)

	it("forgets a deleted board across a /reload", function()
		local client = Client.new():login()
		client:slash("/cork create Scratch")
		client:slash("/cork add temp")
		client:slash("/cork deleteboard Scratch")
		local reloaded = client:reload()
		has(reloaded:slash("/cork boards"), "No boards yet")
	end)

	it("shares boards between characters on the account but keeps the selection per character", function()
		local will = Client.new():login()
		will:slash("/cork create MC")
		local saved = will:logout()
		local alt = Client.new({ saved = saved, name = "Alt", guid = "Player-4372-0ABCDEF1" }):login()
		has(alt:slash("/cork boards"), "MC |cff808080")
		has(alt:slash("/cork list"), "No board selected")
		alt:slash("/cork use MC")
		has(alt:slash("/cork add from the alt"), "Added #1")
		assert.are.equal("6e97d748-0001", next(alt.ns.Corkboard.store:current().notes))
	end)

	it("writes nothing but board data and AceDB bookkeeping", function()
		local client = Client.new():login()
		client:slash("/cork create MC")
		local saved = client:logout()
		local env = {}
		setfenv(assert(loadstring(saved)), env)()
		local keys = {}
		for k in pairs(env.CorkboardDB) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		assert.are.same({ "char", "global", "profileKeys" }, keys)
	end)
end)
