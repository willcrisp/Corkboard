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
		toc = f:read("*a"):gsub("\r\n", "\n") -- a Windows checkout has CRLF
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
			"Core/Invite.lua",
			"Core/Recipes.lua",
			"Core/Players.lua",
			"Core/Store.lua",
			"Core/Commands.lua",
			"Core/View.lua",
			"Core/Wire.lua",
			"Core/Gate.lua",
			"Core/Outbox.lua",
			"Core/Sync.lua",
			"Core/Cloud.lua",
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

describe("Corkboard_Cloud.toc", function()
	it("is data only, loads after Corkboard, and targets Forever", function()
		local f = assert(io.open("addon/Corkboard_Cloud/Corkboard_Cloud.toc", "rb"))
		local toc = f:read("*a"):gsub("\r\n", "\n")
		f:close()
		assert.is_truthy(toc:find("## Interface: 16001\n", 1, true))
		assert.is_truthy(toc:find("## Dependencies: Corkboard\n", 1, true))
		local files = {}
		for line in toc:gmatch("[^\n]+") do
			if not line:find("^#") then
				files[#files + 1] = line
			end
		end
		assert.are.same({ "Data.lua" }, files)
	end)
end)

describe("Corkboard in a fake client", function()
	it("loads, registers its libraries and logs in without errors", function()
		local client = Client.new():login()
		local LibStub = client.env.LibStub
		local libs = {
			"CallbackHandler-1.0", "AceDB-3.0", "LibSerialize", "LibDeflate", "LibDataBroker-1.1", "LibDBIcon-1.0",
		}
		for _, lib in ipairs(libs) do
			assert.is_table(LibStub(lib, true), lib)
		end
		assert.is_table(client.env.ChatThrottleLib)
		local addon = client.ns.Corkboard
		assert.are.equal(addon, client.env.Corkboard)
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

	it("answers /cork through the slash command list", function()
		local client = Client.new():login()
		has(client:slash("/cork help"), "Commands:")
		client:createBoard("Molten Core prep")
		has(client:slash("/CORK invite"), "|cffffd100Corkboard:|r Invite for Molten Core prep.")
	end)

	it("keeps boards and notes across a /reload", function()
		local client = Client.new():login()
		local mc = client:createBoard("Molten Core prep")
		client:addNote("Need 4x " .. LINK)
		client:addNote("Bring fire resistance")
		client:addNote("Summon at the stone")
		client:advance(120)
		client:editNote(2, { text = "Bring fire resistance gear", color = 4 })
		client:deleteNote(3)
		local bwl = client:createBoard("BWL")
		client:store():renameBoard(bwl.id, "BWL prep")
		client:store():select(mc.id)
		local before = client.env.CorkboardDB.global.boards

		local reloaded = client:reload()
		local after = reloaded.env.CorkboardDB.global.boards
		assert.are.same(before, after)

		assert.are.equal(mc.id, reloaded:board().id)
		assert.are.equal("Need 4x " .. LINK .. "\nBring fire resistance gear", reloaded:noteTexts())
		assert.are.equal(4, reloaded:note(2).color)
		assert.are.equal("BWL prep", reloaded.ns.Store.name(reloaded:store():board(bwl.id)))

		-- Ids keep counting past the tombstone that survived the reload.
		assert.are.equal("6f97d8db-0004", reloaded:addNote("After the reload").id)
	end)

	it("forgets a deleted board across a /reload", function()
		local client = Client.new():login()
		local board = client:createBoard("Scratch")
		client:addNote("temp")
		client:store():deleteBoard(board.id)
		local reloaded = client:reload()
		assert.is_nil(next(reloaded:store():all()))
	end)

	it("shares boards between characters on the account but keeps the selection per character", function()
		local will = Client.new():login()
		local mc = will:createBoard("MC")
		local saved = will:logout()
		local alt = Client.new({ saved = saved, name = "Alt", guid = "Player-4372-0ABCDEF1" }):login()
		assert.are.equal(1, #alt:store():boards())
		assert.is_nil(alt:board())
		alt:store():select(mc.id)
		alt:addNote("from the alt")
		assert.are.equal("6e97d748-0001", next(alt:board().notes))
	end)

	it("writes nothing but board data and AceDB bookkeeping", function()
		local client = Client.new():login()
		client:createBoard("MC")
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
