-- Cloud catch-up in the addon (docs/design.md §7.2). The companion writes
-- AddOns/Corkboard_Cloud/Data.lua, which sets the global CorkboardCloudData.
-- At login the addon merges it into the store with the ordinary §4.3 rules,
-- so a stale or repeated Data.lua is harmless. Pure Lua 5.1.
--
--   CorkboardCloudData = {
--     version = 1,
--     written = <unix time the companion wrote the file>,
--     boards = {
--       [boardId] = {
--         cursor = <the API's sequence number the companion has reached>,
--         syncedAt = <unix time of that sync>,
--         notes = { Note, ... }, members = { MemberRecord, ... }, meta = BoardMeta,
--       },
--     },
--   }
--
-- Boards this account doesn't hold are ignored: joining takes an invite.

local _, ns = ...
ns = type(ns) == "table" and ns or {}

local Cloud = {}

Cloud.VERSION = 1

local function isInt(n)
	return type(n) == "number" and n >= 0 and n % 1 == 0
end

-- Merges the companion's data. Returns a summary: { boards, notes, dropped },
-- or nil and a reason when there's nothing usable.
function Cloud.load(store, data)
	if type(data) ~= "table" or type(data.boards) ~= "table" then
		return nil, "none"
	end
	if data.version ~= Cloud.VERSION then
		return nil, "version"
	end
	local summary = { boards = 0, notes = 0, dropped = 0 }
	for id, entry in pairs(data.boards) do
		local board = type(entry) == "table" and store:board(id)
		if board then
			local result = store:applyRemote(id, {
				notes = type(entry.notes) == "table" and entry.notes or nil,
				members = type(entry.members) == "table" and entry.members or nil,
				meta = type(entry.meta) == "table" and entry.meta or nil,
			})
			board.sync = board.sync or {}
			if isInt(entry.syncedAt) and entry.syncedAt > (board.sync.lastCloudAt or 0) then
				board.sync.lastCloudAt = entry.syncedAt
			end
			if isInt(entry.cursor) and entry.cursor > (board.sync.cloudCursor or 0) then
				board.sync.cloudCursor = entry.cursor
			end
			summary.boards = summary.boards + 1
			summary.notes = summary.notes + #result.notes
			summary.dropped = summary.dropped + #result.dropped
		end
	end
	return summary
end

ns.Cloud = Cloud
return Cloud
