local Outbox = require("Core.Outbox")
local Wire = require("Core.Wire")

-- An outbox over a fake clock and transport. Envelopes "encode" to their
-- `text` field so tests control the message count.
local function setup(opts)
	local t = { time = 0, restricted = false, sent = {}, opened = 0, results = {} }
	t.outbox = Outbox.new({
		now = function()
			return t.time
		end,
		restricted = function()
			return t.restricted, t.restricted and "encounter" or nil
		end,
		encode = function(envelope)
			return envelope.text or "x"
		end,
		send = function(dest, text, prio, done)
			t.sent[#t.sent + 1] = { dest = dest, text = text, prio = prio }
			local outcome = table.remove(t.results, 1) or "ok"
			if outcome ~= "later" then
				done(outcome)
			else
				t.pending = done
			end
		end,
		ready = opts and opts.ready,
		onOpen = function()
			t.opened = t.opened + 1
		end,
		burst = opts and opts.burst or 3,
		rate = opts and opts.rate or 1,
	})
	return t
end

local function item(label, fields)
	local it = {
		label = label,
		build = function(self)
			return { t = "PUT", text = self.text or label }
		end,
	}
	for k, v in pairs(fields or {}) do
		it[k] = v
	end
	return it
end

local function texts(t)
	local out = {}
	for i, s in ipairs(t.sent) do
		out[i] = s.text
	end
	return out
end

describe("Outbox", function()
	it("sends by priority: ALERT, then NORMAL, then BULK", function()
		local t = setup({ burst = 10 })
		t.outbox:push(item("bulk", { prio = "BULK" }))
		t.outbox:push(item("normal"))
		t.outbox:push(item("alert", { prio = "ALERT" }))
		t.outbox:pump()
		assert.are.same({ "alert", "normal", "bulk" }, texts(t))
		assert.are.equal("BULK", t.sent[3].prio)
	end)

	it("coalesces items with the same key", function()
		local t = setup()
		local merged = {}
		local first = t.outbox:push(item("put", { key = "PUT:b", merge = function(existing, new)
			merged[#merged + 1] = new.label
			existing.text = "put 1+2"
		end }))
		local second = t.outbox:push(item("put 2", { key = "PUT:b" }))
		assert.are.equal(first, second)
		assert.are.same({ "put 2" }, merged)
		assert.are.equal(1, t.outbox:depth())
		t.outbox:pump()
		assert.are.same({ "put 1+2" }, texts(t))
		-- Once sent, the key is free again.
		t.outbox:push(item("put 3", { key = "PUT:b" }))
		assert.are.equal(1, t.outbox:depth())
	end)

	it("keeps an item at the front while it has more to send", function()
		local t = setup({ burst = 10 })
		local left = 3
		t.outbox:push(item("paged", { build = function()
			left = left - 1
			return { text = "page" .. (3 - left) }, left > 0
		end }))
		t.outbox:push(item("after"))
		t.outbox:pump()
		assert.are.same({ "page1", "page2", "page3", "after" }, texts(t))
	end)

	it("drops items that build nothing", function()
		local t = setup()
		t.outbox:push(item("empty", { build = function()
			return nil, true
		end }))
		t.outbox:pump()
		assert.are.same({}, texts(t))
		assert.are.equal(0, t.outbox:depth())
	end)

	it("spends one token per addon message and refills at the rate", function()
		local t = setup({ burst = 3, rate = 1 })
		for i = 1, 6 do
			t.outbox:push(item("m" .. i))
		end
		t.outbox:pump()
		assert.are.equal(3, #t.sent)
		assert.are.equal(1, t.outbox.stats.stalls)
		t.time = 1.5
		t.outbox:pump()
		assert.are.equal(4, #t.sent)
		t.time = 10
		t.outbox:pump()
		assert.are.equal(6, #t.sent)
	end)

	it("counts a long message as several, and may go into debt for it", function()
		local t = setup({ burst = 3, rate = 1 })
		t.outbox:push(item("big", { text = string.rep("x", Wire.CHUNK * 4) }))
		t.outbox:push(item("small"))
		t.outbox:pump()
		assert.are.equal(1, #t.sent)
		assert.are.equal(4, t.outbox.stats.messages)
		t.time = 1.9
		t.outbox:pump()
		assert.are.equal(1, #t.sent)
		t.time = 2
		t.outbox:pump()
		assert.are.equal(2, #t.sent)
	end)

	it("drops a message too long to send", function()
		local t = setup({ burst = 100 })
		t.outbox:push(item("huge", { text = string.rep("x", Wire.CHUNK * Wire.MAX_CHUNKS + 1) }))
		t.outbox:pump()
		assert.are.equal(0, #t.sent)
		assert.are.equal(1, t.outbox.stats.dropped)
	end)

	it("holds everything while restricted, then flushes and reports the gate opening", function()
		local t = setup({ burst = 10 })
		t.restricted = true
		t.outbox:push(item("a", { prio = "ALERT" }))
		t.outbox:pump()
		assert.are.equal(0, #t.sent)
		assert.is_false(t.outbox.gate.open)
		assert.are.equal("encounter", t.outbox.gate.reason)
		t.restricted = false
		t.time = 2
		t.outbox:pump()
		assert.are.equal(1, t.opened)
		assert.are.same({ "a" }, texts(t))
		assert.are.same({ reason = "encounter", at = 0 }, t.outbox.lastClosed)
	end)

	it("re-queues a message refused as restricted, and waits before retrying", function()
		local t = setup({ burst = 10 })
		t.results = { "lockdown" }
		t.outbox:push(item("edit", { prio = "ALERT" }))
		t.outbox:push(item("other"))
		t.outbox:pump()
		assert.are.same({ "edit" }, texts(t))
		assert.are.equal(2, t.outbox:depth())
		assert.are.equal(1, t.outbox.stats.lockdowns)
		assert.is_false(t.outbox.gate.open)
		t.time = 1
		t.outbox:pump()
		assert.are.equal(1, #t.sent)
		t.time = Outbox.RETRY
		t.outbox:pump()
		assert.are.same({ "edit", "edit", "other" }, texts(t))
		assert.are.equal(1, t.opened)
	end)

	it("counts other failures and doesn't retry them", function()
		local t = setup({ burst = 10 })
		t.results = { "error" }
		t.outbox:push(item("a"))
		t.outbox:pump()
		assert.are.equal(1, t.outbox.stats.errors)
		assert.are.equal(0, t.outbox:depth())
	end)

	it("ignores a second result for the same message", function()
		local t = setup({ burst = 10 })
		t.results = { "later" }
		t.outbox:push(item("a"))
		t.outbox:pump()
		t.pending("error")
		t.pending("lockdown")
		assert.are.equal(1, t.outbox.stats.errors)
		assert.are.equal(0, t.outbox.stats.lockdowns)
	end)

	it("skips destinations that aren't ready, without spending tokens", function()
		local ready = false
		local t = setup({ burst = 1, ready = function(dest)
			return dest.board ~= "b1" or ready
		end })
		t.outbox:push(item("b1", { dest = { board = "b1" } }))
		t.outbox:push(item("b2", { dest = { board = "b2" } }))
		t.outbox:pump()
		assert.are.same({ "b2" }, texts(t))
		ready = true
		t.time = 1
		t.outbox:pump()
		assert.are.same({ "b2" }, texts(t)) -- told to wait RETRY seconds
		t.time = Outbox.RETRY + 0.1
		t.outbox:pump()
		assert.are.same({ "b2", "b1" }, texts(t))
	end)

	it("re-queues a message the transport couldn't place yet", function()
		local t = setup({ burst = 10 })
		t.results = { "wait" }
		t.outbox:push(item("a"))
		t.outbox:pump()
		assert.are.equal(1, t.outbox:depth())
		t.time = Outbox.RETRY
		t.outbox:pump()
		assert.are.same({ "a", "a" }, texts(t))
	end)

	it("cancels by key and by board, and counts per board", function()
		local t = setup()
		t.outbox:push(item("a", { key = "IDX:b1:Bob", board = "b1" }))
		t.outbox:push(item("b", { key = "PUT:b1", board = "b1" }))
		t.outbox:push(item("c", { board = "b2", prio = "BULK" }))
		assert.are.equal(2, t.outbox:depth("b1"))
		assert.is_truthy(t.outbox:queued("IDX:b1:Bob"))
		assert.is_true(t.outbox:cancel("IDX:b1:Bob"))
		assert.is_false(t.outbox:cancel("IDX:b1:Bob"))
		assert.are.equal(1, t.outbox:depth("b1"))
		t.outbox:cancelBoard("b1")
		assert.are.equal(0, t.outbox:depth("b1"))
		assert.is_nil(t.outbox:queued("PUT:b1"))
		assert.are.equal(1, t.outbox:depth())
	end)

	it("rejects an unknown priority", function()
		local t = setup()
		assert.has_error(function()
			t.outbox:push(item("x", { prio = "URGENT" }))
		end)
	end)
end)
