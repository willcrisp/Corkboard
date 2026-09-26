-- The outbox (docs/design.md §5.5, §5.6). Every Corkboard message goes
-- through here: nothing else sends. Pure Lua 5.1; the client comes in through
-- `opts`:
--
--   opts.now()                    monotonic seconds (GetTime())
--   opts.restricted()             true (and a reason) while sends are restricted
--   opts.encode(envelope)         the wire text (Wire:encode)
--   opts.send(dest, text, prio, done)
--                                 hands one message to the transport, which
--                                 calls done(outcome, code) once: outcome is
--                                 "ok", "lockdown", "wait" (not connected
--                                 yet) or "error"
--   opts.ready(dest)              optional: false while the transport can't
--                                 reach dest yet (its channel isn't joined)
--   opts.onOpen()                 called when the gate opens again
--   opts.burst, opts.rate         the throttle budget, in addon messages
--
-- Items wait in three priority queues (ALERT, NORMAL, BULK). An item with a
-- `key` coalesces with the queued item holding that key: its `merge` folds
-- the new one in, so repeated live edits to a note send once. Items build
-- their envelope when they're sent, from the board as it is then, so a
-- coalesced PUT carries the newest version of each note. An item's
-- build(item) returns the envelope (or nil for nothing to send) and whether
-- the item has more to send, in which case it stays at the front.
--
-- The budget is a token bucket in addon messages, refilled at `rate` per
-- second up to `burst`. It models the client's per-prefix throttle (§2); the
-- transport's ChatThrottleLib still paces and re-queues underneath, so an
-- estimate that's a little off costs time, not messages.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Wire = ns.Wire or require("Core.Wire")

local Outbox = {}
Outbox.__index = Outbox

Outbox.PRIORITIES = { "ALERT", "NORMAL", "BULK" }
Outbox.RETRY = 2 -- seconds before retrying after a restriction or an unready transport
-- Budget defaults, a little under the §2 estimate of 1 message/s with a small
-- burst, until spike 02 measures the real throttle.
Outbox.BURST = 8
Outbox.RATE = 0.9

function Outbox.new(opts)
	local now = opts.now()
	local self = setmetatable({
		opts = opts,
		burst = opts.burst or Outbox.BURST,
		rate = opts.rate or Outbox.RATE,
		queues = { ALERT = {}, NORMAL = {}, BULK = {} },
		byKey = {},
		holdUntil = 0,
		gate = { open = true },
		stats = { messages = 0, envelopes = 0, bytes = 0, stalls = 0, lockdowns = 0, errors = 0, dropped = 0 },
	}, Outbox)
	self.tokens, self.at = self.burst, now
	return self
end

-- Queueing -------------------------------------------------------------------------

local function unlink(self, item)
	local queue = self.queues[item.prio]
	for i = 1, #queue do
		if queue[i] == item then
			table.remove(queue, i)
			break
		end
	end
	if item.key and self.byKey[item.key] == item then
		self.byKey[item.key] = nil
	end
end

-- Queues an item, or merges it into the queued item with the same key.
-- Returns the item that's queued.
function Outbox:push(item, front)
	item.prio = item.prio or "NORMAL"
	assert(self.queues[item.prio], "unknown priority")
	local existing = item.key and self.byKey[item.key]
	if existing then
		if existing.merge then
			existing.merge(existing, item)
		end
		return existing
	end
	local queue = self.queues[item.prio]
	if front then
		table.insert(queue, 1, item)
	else
		queue[#queue + 1] = item
	end
	if item.key then
		self.byKey[item.key] = item
	end
	return item
end

-- Removes the queued item with this key, if any.
function Outbox:cancel(key)
	local item = self.byKey[key]
	if item then
		unlink(self, item)
		return true
	end
	return false
end

-- Removes every queued item for a board.
function Outbox:cancelBoard(boardId)
	for _, prio in ipairs(Outbox.PRIORITIES) do
		local queue = self.queues[prio]
		for i = #queue, 1, -1 do
			if queue[i].board == boardId then
				unlink(self, queue[i])
			end
		end
	end
end

function Outbox:queued(key)
	return self.byKey[key]
end

-- Items waiting, for one board or all of them.
function Outbox:depth(boardId)
	local n = 0
	for _, prio in ipairs(Outbox.PRIORITIES) do
		for _, item in ipairs(self.queues[prio]) do
			if not boardId or item.board == boardId then
				n = n + 1
			end
		end
	end
	return n
end

-- The next item that may go now: the highest priority first, skipping items
-- told to wait.
function Outbox:front(now)
	for _, prio in ipairs(Outbox.PRIORITIES) do
		for _, item in ipairs(self.queues[prio]) do
			if not item.notBefore or item.notBefore <= now then
				return item
			end
		end
	end
end

-- The gate and budget ------------------------------------------------------------------

function Outbox:refill(now)
	local tokens = self.tokens + (now - self.at) * self.rate
	self.tokens = tokens < self.burst and tokens or self.burst
	self.at = now
end

function Outbox:close(reason, now)
	if self.gate.open then
		self.gate = { open = false, reason = reason, since = now }
		self.lastClosed = { reason = reason, at = now }
	end
end

-- Sends what the gate and budget allow. Call it after pushing, and on a
-- short ticker so a restricted or throttled queue drains later.
function Outbox:pump()
	local now = self.opts.now()
	if now < self.holdUntil then
		return
	end
	local restricted, reason = self.opts.restricted()
	if restricted then
		self:close(reason or "restricted", now)
		return
	end
	if not self.gate.open then
		self.gate = { open = true }
		if self.opts.onOpen then
			self.opts.onOpen()
		end
	end
	self:refill(now)
	while true do
		local item = self:front(now)
		if not item then
			return
		end
		if self.tokens < 1 then
			self.stats.stalls = self.stats.stalls + 1
			self.stats.lastStall = now
			return
		end
		if self.opts.ready and not self.opts.ready(item.dest) then
			item.notBefore = now + Outbox.RETRY
		else
			local text, label = item.text, item.label
			if text then
				unlink(self, item)
			else
				local envelope, more = item.build(item)
				if not envelope or not more then
					unlink(self, item)
				end
				if envelope then
					text, label = self.opts.encode(envelope), envelope.t
				end
			end
			if text then
				self:dispatch(item, text, label)
				if not self.gate.open or now < self.holdUntil then
					return -- the send was refused as restricted
				end
			end
		end
	end
end

function Outbox:dispatch(item, text, label)
	local chunks = Wire.chunks(text)
	if chunks > Wire.MAX_CHUNKS then
		self.stats.dropped = self.stats.dropped + 1
		return
	end
	self.tokens = self.tokens - chunks
	local stats = self.stats
	stats.envelopes = stats.envelopes + 1
	stats.messages = stats.messages + chunks
	stats.bytes = stats.bytes + #text
	-- What goes back in the queue if the send is refused: the encoded text,
	-- not the builder, so nothing is built twice.
	local sent = { prio = item.prio, dest = item.dest, board = item.board, text = text, label = label }
	local done = false
	self.opts.send(item.dest, text, item.prio, function(outcome, code)
		if done then
			return
		end
		done = true
		self:result(sent, outcome, code)
	end)
end

function Outbox:result(sent, outcome, code)
	local now = self.opts.now()
	self.lastResult = { outcome = outcome, code = code, at = now }
	if outcome == "lockdown" then
		self.stats.lockdowns = self.stats.lockdowns + 1
		self:push(sent, true)
		self:close("send result", now)
		self.holdUntil = now + Outbox.RETRY
	elseif outcome == "wait" then
		sent.notBefore = now + Outbox.RETRY
		self:push(sent)
	elseif outcome ~= "ok" then
		self.stats.errors = self.stats.errors + 1
	end
end

ns.Outbox = Outbox
return Outbox
