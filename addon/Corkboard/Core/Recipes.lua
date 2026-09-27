-- Recipe lists for the Professions tab (docs/design.md §9.2). A character's
-- learned recipes in one profession ride a Note with kind = "recipes", whose
-- text is plain (no escapes, so the sanitiser needs no special case):
--
--   R2;<professionID>;<skill>;<max skill>;<learned>;<profession name>
--   <recipe ids, ascending, in base 36, each after the first as the gap from the one before>
--   <per recipe on the line above: the crafted item's required level in decimal,
--    then c, l, m or p for cloth, leather, mail or plate armour; empty if unknown>
--
-- The third line is left out when no recipe has details. R1 lists (from
-- before the details) have the same first two lines and still read.
--
-- Pure Lua 5.1: the tab's search and rows are built here too, with recipe
-- names coming in through a function from the WoW side.

local _, ns = ...
ns = type(ns) == "table" and ns or {}
local Util = ns.Util or require("Core.Util")
local Sanitise = ns.Sanitise or require("Core.Sanitise")
local Merge = ns.Merge or require("Core.Merge")

local concat, sort = table.concat, table.sort
local find, format, gsub, lower, match, sub = string.find, string.format, string.gsub, string.lower, string.match,
	string.sub

local Recipes = {}

Recipes.KIND = "recipes"
Recipes.MAX_ID = 2147483647 -- profession and recipe ids
Recipes.MAX_SKILL = 9999
Recipes.MAX_NAME = 64 -- bytes of profession name
Recipes.SHOWN = 200 -- rows on the tab
Recipes.MAX_LEVEL = 999 -- a crafted item's required level
-- Armour types a recipe's item can have, in the tab's order, and their letters.
Recipes.ARMOUR = { "cloth", "leather", "mail", "plate" }
Recipes.ARMOUR_NAMES = { cloth = "Cloth", leather = "Leather", mail = "Mail", plate = "Plate" }
local LETTER = { cloth = "c", leather = "l", mail = "m", plate = "p" }
local ARMOUR_OF = { c = "cloth", l = "leather", m = "mail", p = "plate" }

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local HEADER = "^R([12]);(%d+);(%d+);(%d+);(%d+);([^;\n]+)$"
-- 36^6 is above MAX_ID, so no valid id or gap needs more digits.
local MAX_DIGITS = 6

local function base36(n)
	local out = {}
	repeat
		local d = n % 36
		out[#out + 1] = sub(DIGITS, d + 1, d + 1)
		n = (n - d) / 36
	until n == 0
	return string.reverse(concat(out))
end

-- A profession name that fits the header: 1-64 bytes, no ";", "|" or
-- control characters.
function Recipes.validName(name)
	return type(name) == "string" and #name >= 1 and #name <= Recipes.MAX_NAME and not find(name, "[;|%c]")
		and Sanitise.text(name) == true
end

-- One recipe's details as its third-line token: "" when nothing is known.
local function detailToken(detail)
	if type(detail) ~= "table" then
		return ""
	end
	local level = Util.isInteger(detail.level, 1, Recipes.MAX_LEVEL) and tostring(detail.level) or ""
	return level .. (LETTER[detail.armour] or "")
end

-- The note text for one profession. profession = { id, name, skill, max }; ids
-- lists recipe ids (any order, duplicates and bad values ignored); details
-- optionally maps a recipe id to { level, armour } for the item it makes
-- (armour is one of Recipes.ARMOUR). Returns the text and how many ids it
-- holds, or nil and a reason. If every id doesn't fit in a note, the lowest
-- that fit are kept; the header still counts them all.
function Recipes.encode(profession, ids, details)
	if type(profession) ~= "table" or not Util.isInteger(profession.id, 1, Recipes.MAX_ID)
		or not Recipes.validName(profession.name) then
		return nil, "profession"
	end
	local skill, max = profession.skill or 0, profession.max or 0
	if not Util.isInteger(skill, 0, Recipes.MAX_SKILL) or not Util.isInteger(max, 0, Recipes.MAX_SKILL) then
		return nil, "profession"
	end
	local set, list = {}, {}
	for _, id in ipairs(ids or {}) do
		if Util.isInteger(id, 1, Recipes.MAX_ID) and not set[id] then
			set[id] = true
			list[#list + 1] = id
		end
	end
	sort(list)
	details = type(details) == "table" and details or {}
	local header = format("R2;%d;%d;%d;%d;%s", profession.id, skill, max, #list, profession.name)
	-- The ids (and with `withDetails`, their tokens) that fit after the header.
	local function fit(withDetails)
		local parts, extra, size, previous, any = {}, {}, #header, 0, false
		for i, id in ipairs(list) do
			local token, detail = base36(id - previous), withDetails and detailToken(details[id]) or ""
			-- Each token has a line break or comma before it, on both lines.
			local cost = #token + 1 + (withDetails and #detail + 1 or 0)
			if size + cost > Sanitise.MAX_TEXT then
				break
			end
			parts[i], extra[i] = token, detail
			any = any or detail ~= ""
			size = size + cost
			previous = id
		end
		return parts, extra, any
	end
	local parts, extra, any = fit(true)
	if not any then
		-- No third line, so its bytes can hold more ids.
		parts = fit(false)
	end
	if #parts == 0 then
		return header, 0
	end
	local text = header .. "\n" .. concat(parts, ",")
	if any then
		text = text .. "\n" .. concat(extra, ",")
	end
	return text, #parts
end

-- Splits a line on commas, keeping empty fields.
local function fields(line)
	local out = {}
	for field in string.gmatch(line .. ",", "([^,]*),") do
		out[#out + 1] = field
	end
	return out
end

-- Reads a recipe list's text. Returns { id, name, skill, max, learned,
-- recipes, details }, where details maps a recipe id to { level, armour } for
-- the recipes that have any, or nil when the text isn't one (a malformed
-- list is ignored, not repaired).
function Recipes.decode(text)
	if type(text) ~= "string" then
		return nil
	end
	local newline = find(text, "\n", 1, true)
	local header = newline and sub(text, 1, newline - 1) or text
	local body = newline and sub(text, newline + 1) or ""
	local third
	local second = find(body, "\n", 1, true)
	if second then
		body, third = sub(body, 1, second - 1), sub(body, second + 1)
	end
	local version, id, skill, max, learned, name = match(header, HEADER)
	if not id or (third and version ~= "2") or #id > 10 or #skill > 4 or #max > 4 or #learned > 10
		or not Recipes.validName(name) then
		return nil
	end
	local entry = {
		id = tonumber(id),
		name = name,
		skill = tonumber(skill),
		max = tonumber(max),
		learned = tonumber(learned),
		recipes = {},
		details = {},
	}
	if not Util.isInteger(entry.id, 1, Recipes.MAX_ID) or entry.learned > Recipes.MAX_ID then
		return nil
	end
	if newline then
		if body == "" or find(body, "[^0-9a-z,]") or find(body, ",,", 1, true) or sub(body, 1, 1) == ","
			or sub(body, -1) == "," then
			return nil
		end
		local total = 0
		for token in string.gmatch(body, "[^,]+") do
			if #token > MAX_DIGITS then
				return nil
			end
			local gap = tonumber(token, 36)
			if gap < 1 then
				return nil
			end
			total = total + gap
			if total > Recipes.MAX_ID then
				return nil
			end
			entry.recipes[#entry.recipes + 1] = total
		end
	end
	if #entry.recipes > entry.learned then
		return nil
	end
	if third then
		local tokens = fields(third)
		if #tokens ~= #entry.recipes then
			return nil
		end
		for i, token in ipairs(tokens) do
			local level, letter = match(token, "^(%d*)([clmp]?)$")
			if not level or #level > 3 or sub(level, 1, 1) == "0" then
				return nil
			end
			if token ~= "" then
				entry.details[entry.recipes[i]] = { level = tonumber(level), armour = ARMOUR_OF[letter] }
			end
		end
	end
	return entry
end

-- A board's recipe lists, newest per character and profession: a list of
-- { author, note, profession = decoded entry }, by profession name, then author.
function Recipes.lists(board)
	local newest = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted and note.kind == Recipes.KIND then
			local entry = Recipes.decode(note.text)
			if entry then
				local key = note.author .. "\n" .. entry.id
				local held = newest[key]
				if not held or Merge.compareNote(note, held.note) > 0 then
					newest[key] = { author = note.author, note = note, profession = entry }
				end
			end
		end
	end
	local list = {}
	for _, item in pairs(newest) do
		list[#list + 1] = item
	end
	sort(list, function(a, b)
		if a.profession.name ~= b.profession.name then
			return Util.less(a.profession.name, b.profession.name)
		end
		return Util.less(a.author, b.author)
	end)
	return list
end

-- The live recipe-list notes `author` has on the board for one profession,
-- newest first. Normally one; two installs of a character can make more.
function Recipes.mine(board, author, professionId)
	local list = {}
	for _, note in pairs(board.notes or {}) do
		if not note.deleted and note.kind == Recipes.KIND and note.author == author then
			local entry = Recipes.decode(note.text)
			if entry and entry.id == professionId then
				list[#list + 1] = note
			end
		end
	end
	sort(list, function(a, b)
		return Merge.compareNote(a, b) > 0
	end)
	return list
end

-- The recipe's link, as the client builds one (§2). The name comes from the
-- client; anything that could open an escape is taken out.
function Recipes.link(id, name)
	name = type(name) == "string" and gsub(name, "[|%[%]%c]", "") or ""
	if name == "" then
		name = format("Recipe %d", id)
	end
	return format("|cffffd000|Henchant:%d|h[%s]|h|r", id, name)
end

-- The key the tab opens and closes a list by: one character's profession.
function Recipes.key(item)
	return item.author .. "\n" .. item.profession.id
end

-- Recipes by name, then id; a recipe this client can't name sorts first.
local function byName(a, b)
	local an, bn = a.name or "", b.name or ""
	if an ~= bn then
		return Util.less(an, bn)
	end
	return a.id < b.id
end

-- Whether a filter ({ min, max, armour = { [type] = true } }) narrows anything.
function Recipes.filtering(filter)
	return type(filter) == "table" and (filter.min ~= nil or filter.max ~= nil or next(filter.armour or {}) ~= nil)
end

-- Whether a recipe's details pass a filter. With a level bound, a recipe
-- whose level isn't known is left out; with armour types ticked, anything
-- that isn't one of them is.
function Recipes.passes(detail, filter)
	if not Recipes.filtering(filter) then
		return true
	end
	detail = detail or {}
	if (filter.min or filter.max) and not detail.level then
		return false
	end
	if filter.min and detail.level < filter.min or filter.max and detail.level > filter.max then
		return false
	end
	if next(filter.armour or {}) ~= nil and not (detail.armour and filter.armour[detail.armour]) then
		return false
	end
	return true
end

-- What the tab shows beside a recipe: "Level 25 · Leather", or less.
function Recipes.info(detail)
	if not detail then
		return ""
	end
	local parts = {}
	if detail.level then
		parts[#parts + 1] = format("Level %d", detail.level)
	end
	if detail.armour then
		parts[#parts + 1] = Recipes.ARMOUR_NAMES[detail.armour]
	end
	return concat(parts, " · ")
end

-- Rows for the Professions tab. With no search or filter, one row per
-- character and profession, each followed by its recipes when its key is in
-- `open` (a set, see Recipes.key). With a search or a filter, one row per
-- matching recipe with everyone who knows it; every word must appear in the
-- recipe's name, its profession or a knower's name, and the recipe's
-- details must pass the filter (see Recipes.passes). nameOf(id) gives a
-- recipe's name or nil; shortName(author) how to show a character. Returns
-- the rows and whether any were cut.
function Recipes.rows(lists, query, nameOf, shortName, open, filter)
	local rows = {}
	local words = {}
	for word in string.gmatch(lower(query or ""), "%S+") do
		words[#words + 1] = word
	end
	if #words == 0 and not Recipes.filtering(filter) then
		open = open or {}
		for _, item in ipairs(lists) do
			local p = item.profession
			local count = #p.recipes == p.learned and format("%d %s", p.learned, p.learned == 1 and "recipe" or "recipes")
				or format("%d of %d recipes", #p.recipes, p.learned)
			local key = Recipes.key(item)
			local expanded = open[key] == true
			rows[#rows + 1] = {
				index = #rows + 1,
				text = format("%s %d/%d · %s", p.name, p.skill, p.max, count),
				who = shortName(item.author),
				key = key,
				open = expanded,
				empty = #p.recipes == 0,
			}
			if expanded then
				local recipes = {}
				for i, id in ipairs(p.recipes) do
					recipes[i] = { id = id, name = nameOf(id) }
				end
				sort(recipes, byName)
				for _, recipe in ipairs(recipes) do
					rows[#rows + 1] = {
						index = #rows + 1,
						text = Recipes.link(recipe.id, recipe.name),
						who = "",
						info = Recipes.info(p.details and p.details[recipe.id]),
						recipe = true,
						nested = true,
					}
				end
			end
		end
		return rows, false
	end
	local byId, order = {}, {}
	for _, item in ipairs(lists) do
		local details = item.profession.details or {}
		for _, id in ipairs(item.profession.recipes) do
			local recipe = byId[id]
			if not recipe then
				recipe = { id = id, name = nameOf(id), profession = item.profession.name, knowers = {} }
				byId[id] = recipe
				order[#order + 1] = recipe
			end
			recipe.detail = recipe.detail or details[id]
			recipe.knowers[#recipe.knowers + 1] = shortName(item.author)
		end
	end
	local matched = {}
	for _, recipe in ipairs(order) do
		local haystack = lower((recipe.name or "") .. "\n" .. recipe.profession .. "\n" .. concat(recipe.knowers, "\n"))
		local ok = Recipes.passes(recipe.detail, filter)
		for _, word in ipairs(words) do
			if not ok or not find(haystack, word, 1, true) then
				ok = false
				break
			end
		end
		if ok then
			matched[#matched + 1] = recipe
		end
	end
	sort(matched, byName)
	for i = 1, math.min(#matched, Recipes.SHOWN) do
		local recipe = matched[i]
		sort(recipe.knowers, Util.less)
		rows[i] = {
			index = i,
			text = Recipes.link(recipe.id, recipe.name),
			who = concat(recipe.knowers, ", "),
			info = Recipes.info(recipe.detail),
			recipe = true,
		}
	end
	return rows, #matched > Recipes.SHOWN
end

ns.Recipes = Recipes
return Recipes
