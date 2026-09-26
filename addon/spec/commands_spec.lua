local Commands = require("Core.Commands")
local Store = require("Core.Store")

local T0 = 1790000000
local LINK = "|cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r"

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
	local store, env
	before_each(function()
		store, env = newStore()
	end)

	it("prints help for no command, help, ? and unknown commands", function()
		for _, input in ipairs({ "", "   ", "help", "?", "HELP" }) do
			has(run(store, input), "/cork create <name>")
		end
		local out = run(store, "frobnicate")
		has(out, 'Unknown command "frobnicate"')
		has(out, "/cork add <text>")
		has(run(store, nil), "Commands:")
	end)

	it("walks through a board's life", function()
		has(run(store, "boards"), "No boards yet")
		has(run(store, "list"), "No board selected")

		has(run(store, "create Molten Core prep"), "Created board Molten Core prep")
		has(run(store, "boards"), "Molten Core prep (current)")
		has(run(store, "list"), "Molten Core prep: 0 notes")

		has(run(store, "add Need 4x " .. LINK .. " for MC"), "Added #1 to Molten Core prep")
		has(run(store, "add   and a feast  "), "Added #2")
		local list = run(store, "list")
		has(list, "Molten Core prep: 2 notes")
		has(list, "#1 Need 4x " .. LINK .. " for MC")
		has(list, "#2 and a feast |cff808080(Will-Realm, just now)|r")

		has(run(store, "edit 1 Need 6x " .. LINK), "Edited #1")
		has(run(store, "color #2 3"), "#2 is now colour 3")
		list = run(store, "list")
		has(list, "#1 Need 6x " .. LINK)
		has(list, "(Will-Realm, just now, colour 3)")

		has(run(store, "delete 1"), "Deleted #1 from Molten Core prep")
		list = run(store, "list")
		has(list, "1 note")
		assert.is_nil(list:find("Need 6x", 1, true))

		has(run(store, "rename BWL prep"), "Renamed Molten Core prep to BWL prep")
		has(run(store, "boards"), "BWL prep (current) |cff808080- 1 note")

		local board = store:current()
		has(run(store, "deleteboard bwl prep"), "Deleted BWL prep from this account (1 note)")
		assert.is_nil(store:board(board.id))
		has(run(store, "boards"), "No boards yet")
	end)

	it("switches boards by name or id", function()
		run(store, "create MC")
		run(store, "create BWL")
		local mc = store:findBoard("MC")
		has(run(store, "use mc"), "Now using MC")
		assert.are.equal(mc, store:current())
		run(store, "use BWL")
		has(run(store, "use " .. mc.id), "Now using MC")
		has(run(store, "use AQ"), 'No board matches "AQ"')
		run(store, "create mc")
		has(run(store, "use MC"), 'More than one board matches "MC"')
		has(run(store, "deleteboard MC"), "More than one board matches")
		has(run(store, "deleteboard AQ"), 'No board matches "AQ"')
	end)

	it("shows usage when arguments are missing", function()
		run(store, "create MC")
		has(run(store, "create"), "Usage: /cork create <name>")
		has(run(store, "use"), "Usage: /cork use <board>")
		has(run(store, "rename"), "Usage: /cork rename <name>")
		has(run(store, "deleteboard"), "Usage: /cork deleteboard <board>")
		has(run(store, "add"), "Usage: /cork add <text>")
		has(run(store, "edit 1"), "Usage: /cork edit <note> <text>")
		has(run(store, "color 1"), "Usage: /cork color <note> <1-5>")
		has(run(store, "color 1 red"), "Usage: /cork color")
		has(run(store, "delete"), "Usage: /cork delete <note>")
	end)

	it("needs a current board for note commands and rename", function()
		for _, input in ipairs({ "add x", "edit 1 x", "color 1 2", "delete 1", "rename x", "list" }) do
			has(run(store, input), "No board selected")
		end
	end)

	it("explains what the sanitiser refused", function()
		run(store, "create MC")
		has(run(store, "add |TInterface\\Icons\\Spell_Nature_Polymorph:0|t sheep"), "not textures, icons")
		has(run(store, "add |Hunit:Creature-0-1|h[Ragnaros]|h"), "That kind of link can't go on a board")
		has(run(store, "add |Hitem:1"), "That link is malformed")
		has(run(store, "add " .. ("x"):rep(2001)), "Notes are limited to 2000 bytes")
		has(run(store, "add \255"), "isn't valid UTF-8")
		has(run(store, "add a\tb"), "control characters")
		has(run(store, "rename a|b"), "Board names are 1-64 bytes")
		run(store, "add fine")
		has(run(store, "edit 1 |Tx|t"), "not textures, icons")
		has(run(store, "color 9 2"), 'No note "9" on this board')
		has(run(store, "create " .. ("x"):rep(65)), "Board names are 1-64 bytes")
		has(run(store, "list"), "MC: 1 note\n  #1 fine ") -- only the note that passed
	end)

	it("reports note refs it can't use", function()
		run(store, "create MC")
		run(store, "add one")
		has(run(store, "edit 9 x"), 'No note "9" on this board')
		has(run(store, "color 1 6"), "Colours are 1-5")
		has(run(store, "color 1 0"), "Colours are 1-5")
		local id = store:current().notes and next(store:current().notes)
		run(store, "delete 1")
		has(run(store, "delete " .. id), "That note has been deleted")
		has(run(store, "delete 1"), 'No note "1"')
		-- Two authors' notes numbered 1: ask for the full id.
		env.prefix, env.me = "ffffffff", "Bob-Realm"
		run(store, "add from Bob") -- ffffffff-0001
		env.prefix, env.me = "eeeeeeee", "Amy-Realm"
		run(store, "add from Amy") -- eeeeeeee-0001
		has(run(store, "edit 1 x"), "More than one note is #1")
		local list = run(store, "list")
		has(list, "ffffffff-0001 from Bob")
		has(list, "eeeeeeee-0001 from Amy")
		has(run(store, "edit ffffffff-0001 changed"), "Edited ffffffff-0001")
	end)

	it("reports an unknown player and other failures", function()
		run(store, "create MC")
		env.me = nil
		has(run(store, "add x"), "Your character isn't known yet")
		has(run(store, "create x"), "Your character isn't known yet")
		env.me = "Will"
		has(run(store, "create x"), "Your character name couldn't be read")
		env.me = "Will-Realm"
		store:current().notes["a1b2c3d4-999999999"] = {
			id = "a1b2c3d4-999999999", author = "Will-Realm", created = T0, rev = T0, editor = "Will-Realm",
			text = "last", color = 1, deleted = false,
		}
		has(run(store, "add x"), "run out of note ids")
	end)

	it("formats ages", function()
		assert.are.equal("just now", Commands.age(-5))
		assert.are.equal("just now", Commands.age(59))
		assert.are.equal("1m ago", Commands.age(60))
		assert.are.equal("59m ago", Commands.age(3599))
		assert.are.equal("1h ago", Commands.age(3600))
		assert.are.equal("23h ago", Commands.age(86399))
		assert.are.equal("2d ago", Commands.age(2 * 86400))
	end)
end)

describe("/cork sharing commands", function()
	local Invite = require("Core.Invite")

	it("shows the invite and joins from one", function()
		local store = newStore()
		run(store, "create MC")
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
		run(store, "create MC")
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
		run(store, "create MC")
		store:current().owner = "Someone-Else"
		has(run(store, "rotate"), "Only the board's owner")
		has(run(store, "remove Will-Realm"), "Only the board's owner")
	end)

	it("sets the cloud and guild options", function()
		local store = newStore()
		run(store, "create MC")
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
