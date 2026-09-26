-- The merge core must not touch the WoW API (docs/design.md §11), and nor
-- must the rest of Core/ (the store and /cork commands). This loads the Core
-- files the way the client does, with ("Corkboard", ns) as the
-- vararg and no `require`, in an environment holding only Lua 5.1 builtins.
-- Reading any other global, or writing a global, fails the load.

-- Load order in Corkboard.toc (toc_spec checks the two agree).
local CORE = { "Util", "Sanitise", "Merge", "Digest", "Invite", "Store", "Commands", "View", "Wire", "Gate", "Outbox",
	"Sync", "Cloud" }

local BUILTINS = {
	"assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset",
	"select", "setmetatable", "tonumber", "tostring", "type", "unpack", "math", "string", "table",
}

local function sandbox()
	local env = {}
	for _, name in ipairs(BUILTINS) do
		env[name] = _G[name]
	end
	return setmetatable(env, {
		__index = function(_, key)
			error("merge core read global " .. tostring(key), 2)
		end,
		__newindex = function(_, key)
			error("merge core wrote global " .. tostring(key), 2)
		end,
	})
end

local function loadCore()
	local ns = {}
	for _, name in ipairs(CORE) do
		local chunk = assert(loadfile("addon/Corkboard/Core/" .. name .. ".lua"))
		setfenv(chunk, sandbox())
		chunk("Corkboard", ns)
	end
	return ns
end

describe("merge core purity", function()
	it("loads in TOC order with only Lua builtins", function()
		local ns
		assert.has_no.errors(function()
			ns = loadCore()
		end)
		for _, name in ipairs(CORE) do
			assert.is_table(ns[name])
		end
	end)

	it("runs a merge and a digest inside the sandbox", function()
		local ns = loadCore()
		local board = {}
		assert(ns.Merge.createNote(board, { id = "a1b2c3d4-0001", author = "Will-Realm", text = "hi" }, 1790000000))
		assert(ns.Merge.editNote(board, "a1b2c3d4-0001", { text = "there" }, "Bob-Realm", 1790000000))
		assert(ns.Merge.deleteNote(board, "a1b2c3d4-0001", "Bob-Realm", 1790000000))
		assert(ns.Merge.setMember(board, "Bob-Realm", "member", false, "Will-Realm", 1790000000))
		assert.is_number(ns.Digest.compute(board.notes).digest)
	end)

	it("runs the store and /cork commands inside the sandbox", function()
		local ns = loadCore()
		local env = {
			now = function()
				return 1790000000
			end,
			rand = function(n)
				return n
			end,
			me = "Will-Realm",
			prefix = ns.Store.notePrefix("Player-1-00000001"),
		}
		local store = ns.Store.new({ global = { boards = {} }, char = {} }, env)
		local board = assert(store:createBoard("MC"))
		assert(store:addNote(board.id, "hello"))
		assert(ns.Commands.run(store, "invite")[1]:find("Invite for MC", 1, true))
		assert(ns.Commands.run(store, "members")[1]:find("MC: 1 member", 1, true))
	end)
end)
