local View = require("Core.View")

local T0 = 1790000000
local LINK = "|cffa335ee|Hitem:17010::::::::60:::::::::|h[Fiery Core]|h|r"

local function note(fields)
	local t = {
		id = "a1b2c3d4-0001",
		author = "Will-Realm",
		created = T0,
		rev = T0,
		editor = "Will-Realm",
		text = "x",
		color = 1,
		deleted = false,
	}
	for k, v in pairs(fields or {}) do
		t[k] = v
	end
	return t
end

describe("View", function()
	it("has the five muted tags from the style guide", function()
		assert.are.equal(5, #View.TAGS)
		assert.are.same({ "Amber", "Blue", "Green", "Rose", "Violet" }, {
			View.TAGS[1].name, View.TAGS[2].name, View.TAGS[3].name, View.TAGS[4].name, View.TAGS[5].name,
		})
		local amber = View.TAGS[1].color -- #9a7a3c
		assert.are.same({ 0x9a / 255, 0x7a / 255, 0x3c / 255 }, amber)
	end)

	it("maps colours without a tag to the first one", function()
		assert.are.equal(View.TAGS[3], View.tag(3))
		assert.are.equal(View.TAGS[1], View.tag(8))
	end)

	it("formats short ages", function()
		assert.are.equal("now", View.shortAge(-3))
		assert.are.equal("now", View.shortAge(59))
		assert.are.equal("1m", View.shortAge(60))
		assert.are.equal("40m", View.shortAge(40 * 60))
		assert.are.equal("2h", View.shortAge(2 * 3600 + 5))
		assert.are.equal("1d", View.shortAge(86400))
	end)

	it("drops the realm only for the player's own realm", function()
		assert.are.equal("Will", View.shortName("Will-Realm", "Realm"))
		assert.are.equal("Bob-Other", View.shortName("Bob-Other", "Realm"))
		assert.are.equal("Bob-Azjol-Nerub", View.shortName("Bob-Azjol-Nerub", "Realm"))
		assert.are.equal("Bob", View.shortName("Bob-Azjol-Nerub", "Azjol-Nerub"))
		assert.are.equal("Realm", View.realmOf("Will-Realm"))
		assert.is_nil(View.realmOf(nil))
	end)

	it("reduces text to what a reader sees", function()
		assert.are.equal("Need 4x [Fiery Core] now", View.plainText("Need 4x " .. LINK .. " now"))
		assert.are.equal("red and plain", View.plainText("|cffff0000red|r and |cnIQ4:plain|r"))
		assert.are.equal("a|b", View.plainText("a||b"))
	end)

	describe("search", function()
		local notes = {
			note({ id = "a1b2c3d4-0001", text = "Need 4x " .. LINK }),
			note({ id = "a1b2c3d4-0002", text = "Repair before you zone in", editor = "Mira-Realm" }),
			note({ id = "a1b2c3d4-0003", text = "Raid Tuesday", author = "Bob-Realm", editor = "Bob-Realm" }),
		}

		it("matches link text, ignoring case and escape codes", function()
			assert.are.equal(1, #View.filter(notes, "fiery"))
			assert.are.equal(0, #View.filter(notes, "hitem"))
			assert.are.equal(0, #View.filter(notes, "a335ee"))
		end)

		it("needs every word", function()
			assert.are.same({ notes[2] }, View.filter(notes, "  zone   REPAIR "))
			assert.are.same({}, View.filter(notes, "zone tuesday"))
		end)

		it("matches the author and editor", function()
			assert.are.same({ notes[3] }, View.filter(notes, "bob"))
			assert.are.same({ notes[2] }, View.filter(notes, "mira"))
		end)

		it("keeps everything for an empty query", function()
			assert.are.equal(3, #View.filter(notes, ""))
			assert.are.equal(3, #View.filter(notes, "   "))
			assert.are.equal(3, #View.filter(notes, nil))
		end)

		it("treats the query as plain text, not a pattern", function()
			assert.are.equal(0, #View.filter(notes, "%a"))
			assert.are.equal(0, #View.filter(notes, "(fiery"))
			assert.are.equal(1, #View.filter(notes, "[fiery")) -- a literal bracket, as shown
		end)
	end)

	it("groups notes into rows of two", function()
		local a, b, c = note(), note(), note()
		assert.are.same({}, View.rows({}))
		assert.are.same({ { a } }, View.rows({ a }))
		assert.are.same({ { a, b }, { c } }, View.rows({ a, b, c }))
	end)

	it("writes the byline", function()
		assert.are.equal("Will", View.byline(note(), "Realm"))
		assert.are.equal("Will · edited by Mira", View.byline(note({ editor = "Mira-Realm" }), "Realm"))
		assert.are.equal("Will-Realm · edited by Mira-Realm", View.byline(note({ editor = "Mira-Realm" }), "Other"))
	end)

	it("writes the editor header", function()
		assert.are.equal("MC · new note", View.editorHeader("MC", nil, T0, "Realm"))
		assert.are.equal(
			"MC · created by Will 2h ago",
			View.editorHeader("MC", note({ created = T0 - 7200, rev = T0 - 7200 }), T0, "Realm")
		)
		assert.are.equal(
			"MC · created by Will 2h ago · edited by Bob 14m ago",
			View.editorHeader("MC", note({ created = T0 - 7200, rev = T0 - 840, editor = "Bob-Realm" }), T0, "Realm")
		)
	end)

	it("counts bytes against the sanitiser's limit", function()
		assert.are.same({ "0 / 2000", false }, { View.counter("") })
		assert.are.same({ "2 / 2000", false }, { View.counter("ø") })
		assert.are.same({ "2000 / 2000", false }, { View.counter(("x"):rep(2000)) })
		assert.are.same({ "2001 / 2000", true }, { View.counter(("x"):rep(2001)) })
	end)

	it("refuses to save what a peer would drop", function()
		assert.is_true(View.check("Need 4x " .. LINK))
		assert.are.same({ false, "Write something first." }, { View.check("") })
		assert.are.same({ false, "Write something first." }, { View.check(" \n ") })
		local ok, message = View.check("|TInterface\\Icons\\x:0|t")
		assert.is_false(ok)
		assert.is_truthy(message:find("not textures, icons", 1, true))
		ok, message = View.check(("x"):rep(2001))
		assert.is_false(ok)
		assert.is_truthy(message:find("2000 bytes", 1, true))
	end)

	it("only reports real changes", function()
		local n = note({ text = "a", color = 2 })
		assert.is_nil(View.changes(n, "a", 2))
		assert.are.same({ text = "b" }, View.changes(n, "b", 2))
		assert.are.same({ color = 3 }, View.changes(n, "a", 3))
		assert.are.same({ text = "b", color = 3 }, View.changes(n, "b", 3))
	end)

	it("writes the status line and board detail", function()
		assert.are.same({ "Local only: sync arrives with invites", "6 notes" }, { View.status(6, 6) })
		assert.are.same({ "Local only: sync arrives with invites", "1 note" }, { View.status(1, 1) })
		assert.are.same({ "Local only: sync arrives with invites", "0 notes" }, { View.status(0, 0) })
		assert.are.same({ "Local only: sync arrives with invites", "2 of 6 notes" }, { View.status(6, 2) })
		assert.are.equal("1 note", View.boardDetail(1))
		assert.are.equal("3 notes", View.boardDetail(3))
	end)
end)
