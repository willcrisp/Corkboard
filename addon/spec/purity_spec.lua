-- The merge core must not touch the WoW API (docs/design.md §11). This loads
-- the Core files the way the client does, with ("Corkboard", ns) as the
-- vararg and no `require`, in an environment holding only Lua 5.1 builtins.
-- Reading any other global, or writing a global, fails the load.

-- Load order for the TOC.
local CORE = { "Util", "Sanitise", "Merge", "Digest" }

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
end)
