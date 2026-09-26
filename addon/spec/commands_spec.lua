local Commands = require("Core.Commands")
local Store = require("Core.Store")

local T0 = 1790000000

local function newStore()
	local seed = 1
	local env = {
		now = function()
			return T0
		end,
		rand = function(n)
			seed = seed * 16807 % 2147483647
			return seed % n + 1
		end,
		me = "Will-Realm",
		prefix = "a1b2c3d4",
	}
	return Store.new({ global = { boards = {} }, char = {} }, env), env
end

-- Runs a command and returns its output as one string, lines joined by "\n".
local function run(store, input)
	return table.concat(Commands.run(store, input), "\n")
end

local function has(output, text)
	assert(output:find(text, 1, true), ("expected %q in:\n%s"):format(text, output))
end

describe("/cork", function()
	local store
	before_each(function()
		store = newStore()
	end)

	it("prints help for no command, help, ? and unknown commands", function()
		for _, input in ipairs({ "", "   ", "help", "?", "HELP" }) do
			has(run(store, input), "/cork join <invite>")
		end
		local out = run(store, "frobnicate")
		has(out, 'Unknown command "frobnicate"')
		has(out, "/cork invite")
		has(run(store, nil), "Commands:")
	end)

	it("explains store and sanitiser reasons", function()
		has(Commands.explain("escape"), "not textures, icons")
		has(Commands.explain("link_type"), "That kind of link can't go on a board")
		has(Commands.explain("link"), "That link is malformed")
		has(Commands.explain("too_long"), "Notes are limited to 2000 bytes")
		has(Commands.explain("utf8"), "isn't valid UTF-8")
		has(Commands.explain("control"), "control characters")
		has(Commands.explain("name"), "Board names are 1-64 bytes")
		has(Commands.explain("identity"), "Your character isn't known yet")
		has(Commands.explain("id_space"), "run out of note ids")
		has(Commands.explain("frob"), "That didn't work (frob).")
	end)

	it("formats ages and counts", function()
		assert.are.equal("just now", Commands.age(-5))
		assert.are.equal("just now", Commands.age(59))
		assert.are.equal("1m ago", Commands.age(60))
		assert.are.equal("59m ago", Commands.age(3599))
		assert.are.equal("1h ago", Commands.age(3600))
		assert.are.equal("23h ago", Commands.age(86399))
		assert.are.equal("2d ago", Commands.age(2 * 86400))
		assert.are.equal("now", Commands.shortAge(59))
		assert.are.equal("2h", Commands.shortAge(2 * 3600))
		assert.are.equal("1 note", Commands.plural(1, "note"))
		assert.are.equal("0 notes", Commands.plural(0, "note"))
	end)
end)

describe("/cork sharing commands", function()
	local Invite = require("Core.Invite")

	it("shows the invite and joins from one", function()
		local store = newStore()
		assert(store:createBoard("MC"))
		local out = run(store, "invite")
		local code = out:match("(CORK1:%S+)")
		assert.is_truthy(Invite.decode(code))
		has(out, "Members tab")
		local other = Store.new({ global = { boards = {} }, char = {} }, { now = function()
			return T0
		end, rand = math.random, me = "Bob-Realm", prefix = "b0b0b0b0" })
		has(run(other, "join " .. code), "Joined")
		has(run(other, "join " .. code), "already on")
		has(run(other, "join nonsense"), "isn't a Corkboard invite")
		has(run(other, "join CORK2:abc"), "newer version")
		has(run(other, "join CORK1:!!"), "damaged")
		has(run(other, "join"), "Usage: /cork join")
	end)

	it("lists members, and lets the owner remove one and rotate", function()
		local store = newStore()
		assert(store:createBoard("MC"))
		local board = store:current()
		require("Core.Merge").applyMember(board, { name = "Bob-Realm", role = "member", rev = T0, editor = "Bob-Realm",
			removed = false })
		board.seen = { ["Bob-Realm"] = { at = T0 - 120 } }
		local out = run(store, "members")
		has(out, "MC: 2 members")
		has(out, "Will-Realm |cff808080(owner)|r")
		has(out, "Bob-Realm |cff808080(member, seen 2m ago)|r")
		has(run(store, "remove"), "Usage: /cork remove")
		has(run(store, "remove Nobody-Realm"), "aren't a member")
		local secret = board.secret
		has(run(store, "remove Bob-Realm"), "Removed Bob-Realm from MC")
		assert.are_not.equal(secret, board.secret)
		has(run(store, "rotate"), "has a new secret")
	end)

	it("refuses owner commands from members", function()
		local store = newStore()
		assert(store:createBoard("MC"))
		store:current().owner = "Someone-Else"
		has(run(store, "rotate"), "Only the board's owner")
		has(run(store, "remove Will-Realm"), "Only the board's owner")
	end)

	it("sets the cloud and guild options", function()
		local store = newStore()
		assert(store:createBoard("MC"))
		has(run(store, "cloud off"), "Cloud sync for MC is off.")
		assert.is_false(store:current().cloud)
		has(run(store, "guild ON"), "Guild sync for MC is on.")
		assert.is_true(store:current().guild)
		has(run(store, "cloud maybe"), "Usage: /cork cloud on|off")
	end)

	it("needs a current board", function()
		local store = newStore()
		for _, command in ipairs({ "invite", "members", "remove X-Y", "rotate", "cloud on" }) do
			has(run(store, command), "No board selected")
		end
	end)
end)
