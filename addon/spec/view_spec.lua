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
		assert.are.equal("6 notes", View.count(6, 6))
		assert.are.equal("1 note", View.count(1, 1))
		assert.are.equal("0 notes", View.count(0, 0))
		assert.are.equal("2 of 6 notes", View.count(6, 2))
		assert.are.equal("1 note", View.boardDetail(1))
		assert.are.equal("1 note", View.boardDetail(1, 0))
		assert.are.equal("3 notes · 2 online", View.boardDetail(3, 2))
		assert.are.equal("3 notes", View.boardDetail(3))
	end)
end)

describe("View sync status", function()
	local NOW = 1790010000
	local function status(fields)
		local s = { online = {}, queued = 0, paused = false, cloud = true }
		for k, v in pairs(fields or {}) do
			s[k] = v
		end
		return s
	end

	it("puts the most urgent state first", function()
		local s = status({ paused = true, queued = 3, behind = 142, online = { "Bob-Realm" } })
		assert.are.same({ label = "Invite out of date", detail = "· ask the owner for a new one", dot = "behind" },
			View.syncStatus(s, "expired", NOW, "Realm"))
		assert.are.same({ label = "Paused", detail = "· 3 messages queued", dot = "paused" },
			View.syncStatus(s, "joined", NOW, "Realm"))
		assert.are.equal("· sends when allowed", View.syncStatus(status({ paused = true }), "joined", NOW).detail)
		assert.are.same({ label = "142 notes behind", detail = "· /reload after cloud sync", dot = "behind" },
			View.syncStatus(status({ behind = 142 }), "joined", NOW, "Realm"))
		assert.are.same({ label = "Syncing", detail = "· 12 notes from Kael", dot = "syncing", hollow = true },
			View.syncStatus(status({ syncing = { from = "Kael-Realm", left = 12 } }), "joined", NOW, "Realm"))
	end)

	it("says when a board isn't connected", function()
		assert.are.equal("Not connected", View.syncStatus(status(), "limit", NOW).label)
		local joining = View.syncStatus(status(), "joining", NOW)
		assert.are.equal("Connecting", joining.label)
		assert.is_true(joining.hollow)
	end)

	it("names the last member synced with, and the cloud", function()
		local s = status({ online = { "Bob-Realm" }, lastPeer = "Bob-Realm", lastPeerAt = NOW - 180,
			lastCloudAt = NOW - 7200 })
		assert.are.same({ label = "Synced with Bob 3m ago", detail = "· Cloud 2h ago", dot = "synced" },
			View.syncStatus(s, "joined", NOW, "Realm"))
		s.lastPeer = nil
		assert.are.equal("1 online", View.syncStatus(s, "joined", NOW, "Realm").label)
		s.lastCloudAt = nil
		assert.are.equal("· cloud not synced yet", View.syncStatus(s, "joined", NOW, "Realm").detail)
		s.cloud = false
		assert.are.equal("· cloud off", View.syncStatus(s, "guild", NOW, "Realm").detail)
	end)

	it("covers nobody online, with and without the cloud", function()
		assert.are.same({ label = "Nobody online", detail = "· Cloud 1d ago", dot = "idle", hollow = true, dim = true },
			View.syncStatus(status({ lastCloudAt = NOW - 90000 }), "joined", NOW))
		assert.are.same({ label = "In-game sync only", detail = "· cloud off", dot = "idle", dim = true },
			View.syncStatus(status({ cloud = false }), "joined", NOW))
	end)

	it("has a colour for every dot", function()
		for _, dot in ipairs({ "synced", "syncing", "paused", "behind", "idle" }) do
			assert.are.equal(3, #View.DOTS[dot])
		end
	end)
end)

describe("View roster, tooltip and debug", function()
	local NOW = 1790010000

	it("says how long ago a member was seen", function()
		assert.are.equal("1 minute", View.seen(5))
		assert.are.equal("5 minutes", View.seen(300))
		assert.are.equal("3 hours", View.seen(3 * 3600 + 5))
		assert.are.equal("2 days", View.seen(2 * 86400))
	end)

	it("builds roster rows", function()
		local board = { owner = "Will-Realm", seen = {
			["Bob-Realm"] = { at = NOW - 60, class = "PRIEST" },
			["Mira-Other"] = { at = NOW - 3 * 3600 },
		} }
		local members = {
			{ name = "Will-Realm", role = "owner" },
			{ name = "Bob-Realm", role = "member" },
			{ name = "Mira-Other", role = "member" },
			{ name = "Dorn-Realm", role = "member" },
		}
		local peers = { ["Bob-Realm"] = { state = "match" }, ["Mira-Other"] = { cloud = NOW - 7200 } }
		local rows = View.memberRows(board, members, peers, { "Bob-Realm" }, "Will-Realm", NOW, "Realm")
		assert.are.same({ name = "Will-Realm", label = "Will", role = "Owner", online = true, removable = false,
			seen = "You", sync = "-" }, rows[1])
		assert.are.same({ name = "Bob-Realm", label = "Bob", role = "Member", class = "PRIEST", online = true,
			removable = true, seen = "Online", sync = "Up to date" }, rows[2])
		assert.are.same({ name = "Mira-Other", label = "Mira-Other", role = "Member", online = false,
			removable = true, seen = "3 hours", sync = "Cloud 2h ago" }, rows[3])
		assert.are.equal("Never", rows[4].seen)
		assert.are.equal("-", rows[4].sync)
		peers["Bob-Realm"].state = "differs"
		assert.are.equal("Syncing", View.memberRows(board, members, peers, { "Bob-Realm" }, "Will-Realm", NOW)[2].sync)
		assert.is_false(View.memberRows(board, members, nil, {}, "Bob-Realm", NOW)[1].removable)
	end)

	it("lists boards in the broker tooltip", function()
		local list = {}
		for i = 1, 9 do
			list[i] = { id = "board" .. i, meta = i ~= 2 and { name = "Board " .. i } or nil }
		end
		local store = { boards = function()
			return list
		end }
		local sync = { status = function(_, id)
			if id == "board1" then
				return { online = { "a", "b", "c" }, queued = 0 }
			elseif id == "board2" then
				return { online = {}, queued = 2, paused = true }
			end
			return { online = {}, queued = 0 }
		end }
		local lines = View.tooltipLines(store, sync)
		assert.are.equal("Board 1", lines[1][1])
		assert.are.equal("  3 online", lines[2][1])
		assert.are.equal("board2", lines[3][1])
		assert.are.equal("  2 queued", lines[4][1])
		assert.are.equal("  Nobody online", lines[6][1])
		assert.are.equal("and 1 more", lines[#lines][1])
	end)

	it("writes the debug stats", function()
		local outbox = {
			stats = { stalls = 2, lastStall = 100, envelopes = 3, messages = 5, bytes = 900, lockdowns = 1, errors = 0,
				dropped = 0 },
			gate = { open = true },
			lastClosed = { at = 40, reason = "encounter" },
			tokens = 4.25,
			burst = 8,
			depth = function()
				return 0
			end,
		}
		local stats = View.debugStats(outbox, "C_ChatInfo.InChatMessagingLockdown", { clock = 1790004412 }, 158)
		assert.are.same({ "Send gate", "Open · C_ChatInfo.InChatMessagingLockdown" }, stats[1])
		assert.are.same({ "Last closed", "1m ago (encounter)" }, stats[2])
		assert.are.same({ "Throttle stalls", "2 (now ago)" }, stats[4])
		assert.are.same({ "Budget", "4.2 / 8 messages" }, stats[7])
		assert.are.same({ "Board clock", "1790004412" }, stats[8])
		outbox.gate = { open = false, reason = "encounter" }
		outbox.lastClosed, outbox.stats.lastStall = nil, nil
		stats = View.debugStats(outbox, "none", nil, 158)
		assert.are.equal("Closed (encounter) · none", stats[1][2])
		assert.are.equal("never", stats[2][2])
		assert.are.equal("0", stats[4][2])
		assert.are.equal("-", stats[8][2])
		assert.are.equal("45:1790004412:9f3a01c2", View.digestLabel(45, 1790004412, 0x9f3a01c2))
		assert.are.equal("0:0:00000000", View.digestLabel())
	end)
end)
