-- A discrete-event simulation of Corkboard members talking over a board
-- channel (docs/design.md §11): each node has its own store, outbox and sync
-- engine over plain tables, the real wire format (LibSerialize + LibDeflate)
-- and chunking, a per-sender server throttle, and message latency.
--
--   local sim = Sim.new({ seed = 1 })
--   local a, b = sim:add("Will"), sim:add("Bob")
--   local board = a.store:createBoard("MC")
--   b.store:joinBoard(Invite.encode(board))
--   sim:run(10)
--
-- The throttle model is the §11 one: a token bucket of `burst` messages
-- refilled at `rate` per second per sender. A chunk sent over budget waits
-- for a token, as ChatThrottleLib re-queues a throttled send.

local Store = require("Core.Store")
local Outbox = require("Core.Outbox")
local Sync = require("Core.Sync")
local Wire = require("Core.Wire")
local Libs = require("helpers.libs")

local Sim = {}
Sim.__index = Sim

Sim.T0 = 1790000000

-- Park-Miller.
local function prng(seed)
	local state = seed % 2147483646 + 1
	return function()
		state = state * 16807 % 2147483647
		return (state - 1) / 2147483646
	end
end

function Sim.new(opts)
	opts = opts or {}
	local self = setmetatable({
		time = 0,
		events = {},
		seq = 0,
		nodes = {},
		wire = Libs.wire(),
		random = prng(opts.seed or 1),
		latency = opts.latency or { 0.05, 0.25 },
		burst = opts.burst or 10,
		rate = opts.rate or 1,
		loss = opts.loss or 0,
		messages = {}, -- every envelope sent: { time, from, t, to, bytes, chunks }
		lanes = {}, -- "sender>receiver" -> time of the last delivery
	}, Sim)
	return self
end

-- Events ------------------------------------------------------------------------

function Sim:at(time, fn)
	self.seq = self.seq + 1
	local event = { time = time, seq = self.seq, fn = fn }
	local events = self.events
	local i = #events
	while i > 0 and (events[i].time > time or (events[i].time == time and events[i].seq > event.seq)) do
		i = i - 1
	end
	table.insert(events, i + 1, event)
	return {
		Cancel = function()
			event.cancelled = true
		end,
	}
end

function Sim:run(seconds)
	local stop = self.time + seconds
	while self.events[1] and self.events[1].time <= stop do
		local event = table.remove(self.events, 1)
		self.time = event.time
		if not event.cancelled then
			event.fn()
		end
	end
	self.time = stop
end

-- Runs until check() is true or `limit` seconds pass. Returns the seconds taken, or nil.
function Sim:runUntil(check, limit, step)
	local start = self.time
	step = step or 0.5
	while self.time - start < limit do
		if check() then
			return self.time - start
		end
		self:run(step)
	end
	if check() then
		return self.time - start
	end
	return nil
end

function Sim:serverTime()
	return Sim.T0 + math.floor(self.time)
end

-- Nodes -------------------------------------------------------------------------------

function Sim:add(name, opts)
	opts = opts or {}
	local node = {
		sim = self,
		name = name .. "-Realm",
		db = { global = { boards = {} }, char = {} },
		online = false,
		locked = false,
		epoch = 0,
		tokens = self.burst,
		tokensAt = 0,
		nextFree = 0,
		received = {},
	}
	node.env = {
		now = function()
			return self:serverTime() + (opts.skew or 0)
		end,
		rand = function(n)
			return math.floor(self.random() * n) + 1
		end,
		me = node.name,
		prefix = Store.notePrefix("Player-" .. name),
	}
	self.nodes[#self.nodes + 1] = node
	self:login(node)
	return node
end

-- A node's timers only fire during the session that set them.
function Sim:nodeAfter(node, delay, fn)
	local epoch = node.epoch
	return self:at(self.time + delay, function()
		if node.online and node.epoch == epoch then
			fn()
		end
	end)
end

-- Logs in (or relogs): a fresh store, outbox and sync engine over the same
-- saved tables, as after a /reload.
function Sim:login(node)
	node.epoch = node.epoch + 1
	node.online = true
	node.store = Store.new(node.db, node.env)
	node.reassembler = Wire.Reassembler.new()
	node.outbox = Outbox.new({
		now = function()
			return self.time
		end,
		restricted = function()
			return node.locked, node.locked and "encounter" or nil
		end,
		encode = function(envelope)
			return self.wire:encode(envelope)
		end,
		send = function(dest, text, prio, done)
			self:transmit(node, dest, text, prio)
			done("ok")
		end,
		ready = function(dest)
			return self:onChannel(node, dest.board)
		end,
		onOpen = function()
			node.sync:onGateOpen()
		end,
	})
	node.sync = Sync.new(node.store, node.outbox, {
		time = function()
			return self.time
		end,
		after = function(delay, fn)
			return self:nodeAfter(node, delay, fn)
		end,
		random = self.random,
		class = "MAGE",
	})
	local function tick()
		node.outbox:pump()
		self:nodeAfter(node, 0.5, tick)
	end
	self:nodeAfter(node, 0.5, tick)
	node.sync:start()
end

function Sim.logout(_, node)
	node.online = false
end

-- The board channel ----------------------------------------------------------------------

-- A node is on a board's channel while it's online and holds the board with
-- the channel's current secret (the channel password).
function Sim.onChannel(_, node, boardId, secret)
	if not node.online then
		return false
	end
	local board = node.db.global.boards[boardId]
	return board ~= nil and (secret == nil or board.secret == secret)
end

function Sim:delay()
	local lo, hi = self.latency[1], self.latency[2]
	return lo + self.random() * (hi - lo)
end

-- When a sender's next chunk leaves, under the server throttle.
function Sim:slot(node)
	local now = self.time
	local t = math.max(now, node.nextFree)
	node.tokens = math.min(self.burst, node.tokens + (t - node.tokensAt) * self.rate)
	node.tokensAt = t
	if node.tokens < 1 then
		t = t + (1 - node.tokens) / self.rate
		node.tokens = 1
		node.tokensAt = t
	end
	node.tokens = node.tokens - 1
	node.nextFree = t
	return t
end

function Sim:transmit(node, dest, text, prio)
	local board = node.db.global.boards[dest.board]
	if not board then
		return
	end
	local secret = board.secret
	local envelope = self.wire:decode(text)
	local chunks = assert(Wire.split(text))
	self.messages[#self.messages + 1] = {
		time = self.time,
		from = node.name,
		t = envelope.t,
		to = envelope.to,
		board = dest.board,
		bytes = #text,
		chunks = #chunks,
		prio = prio,
		envelope = envelope,
	}
	for _, chunk in ipairs(chunks) do
		local leaves = self:slot(node)
		for _, other in ipairs(self.nodes) do
			if other ~= node and self.random() >= self.loss then
				-- One sender's messages reach each receiver in order.
				local lane = node.name .. ">" .. other.name
				local at = math.max(leaves + self:delay(), self.lanes[lane] or 0)
				self.lanes[lane] = at
				self:at(at, function()
					self:deliver(other, node.name, dest.board, secret, chunk)
				end)
			end
		end
	end
end

function Sim:deliver(node, sender, boardId, secret, chunk)
	if not self:onChannel(node, boardId, secret) then
		return
	end
	local text = node.reassembler:add(sender .. "\0" .. boardId, chunk, self.time)
	if not text then
		return
	end
	local envelope = self.wire:decode(text)
	if envelope then
		node.received[#node.received + 1] = { time = self.time, from = sender, t = envelope.t, envelope = envelope }
		node.sync:receive(envelope, sender)
		node.outbox:pump()
	end
end

-- Checks ------------------------------------------------------------------------------------

function Sim.board(node, id)
	return node.db.global.boards[id]
end

function Sim.digest(node, id)
	local board = Sim.board(node, id)
	return board and node.sync:summary(board).digest
end

-- Whether every node given holds the board with the same notes, members and name.
function Sim.converged(nodes, id)
	local first = nodes[1]
	local d = Sim.digest(first, id)
	local board = Sim.board(first, id)
	for i = 2, #nodes do
		local other = Sim.board(nodes[i], id)
		if not other or Sim.digest(nodes[i], id) ~= d then
			return false
		end
		if Sync.membersDigest(other.members) ~= Sync.membersDigest(board.members) then
			return false
		end
		if (other.meta and other.meta.name) ~= (board.meta and board.meta.name) then
			return false
		end
	end
	return true
end

-- Messages sent since `since`, optionally of one type.
function Sim:sent(t, since)
	local out = {}
	for _, m in ipairs(self.messages) do
		if (not t or m.t == t) and m.time >= (since or 0) then
			out[#out + 1] = m
		end
	end
	return out
end

return Sim
