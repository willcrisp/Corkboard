-- The board window and note editor, clicked through in the fake client the
-- way a player would. This catches Lua errors and wiring mistakes; how the
-- frames look can only be checked in game.

local Client = require("helpers.client")

local LINK = "|cffa335ee|Hitem:17010::::::::60:::::::::|h[Fiery Core]|h|r"

local function has(output, text)
	assert(output:find(text, 1, true), ("expected %q in:\n%s"):format(text, output))
end

-- The visible button with this label.
local function buttonNamed(client, label)
	for _, frame in ipairs(client.frames) do
		if frame.kind == "Button" and frame.text == label and frame:IsVisible() then
			return frame
		end
	end
	error("no visible button " .. label)
end

-- The visible note cards, in grid order.
local function cards(client)
	local out = {}
	for _, frame in ipairs(client.frames) do
		if frame.template == "BackdropTemplate" and frame.noteId and frame:IsVisible() then
			out[#out + 1] = frame
		end
	end
	return out
end

local function cardTexts(client)
	local out = {}
	for i, card in ipairs(cards(client)) do
		out[i] = card.text.text
	end
	return out
end

-- The visible rows of the board list.
local function boardRows(client)
	local out = {}
	for _, frame in ipairs(client.frames) do
		if frame.template == "WowScrollBoxList" and frame.elements then
			for _, row in ipairs(frame.elements) do
				if row.boardId and row:IsVisible() then
					out[#out + 1] = row
				end
			end
		end
	end
	return out
end

-- Every label a frame has created, one per line.
local function labels(frame)
	local out = {}
	for i, fontString in ipairs(frame.fontStrings or {}) do
		out[i] = fontString.text
	end
	return table.concat(out, "\n")
end

local function editorText(client)
	return client.env.CorkboardEditorText
end

local function store(client)
	return client.ns.Corkboard.store
end

local function openWindow()
	local client = Client.new():login()
	client:slash("/cork")
	return client
end

describe("the board window", function()
	it("opens and closes with /cork and closes on Escape", function()
		local client = openWindow()
		local frame = client.env.CorkboardFrame
		assert.is_true(frame:IsShown())
		assert.are.equal("PortraitFrameTemplate", frame.template)
		assert.are.equal("Corkboard", frame.title)
		client:slash("/cork")
		assert.is_false(frame:IsShown())
		assert.are.same({ "CorkboardFrame" }, client.env.UISpecialFrames)
	end)

	it("opens from the broker launcher and the addon compartment", function()
		local client = Client.new():login()
		local launcher = client.env.LibStub("LibDataBroker-1.1"):GetDataObjectByName("Corkboard")
		launcher.OnClick()
		assert.is_true(client.env.CorkboardFrame:IsShown())
		client.env.CorkboardCompartment_OnClick()
		assert.is_false(client.env.CorkboardFrame:IsShown())
	end)

	it("starts empty, with only New enabled", function()
		local client = openWindow()
		assert.is_false(buttonNamed(client, "New Note").enabled)
		assert.is_false(buttonNamed(client, "Rename").enabled)
		assert.is_false(buttonNamed(client, "Delete").enabled)
		assert.is_true(buttonNamed(client, "New").enabled)
		assert.are.same({}, cards(client))
	end)

	it("creates, renames and deletes boards through popups", function()
		local client = openWindow()
		buttonNamed(client, "New"):Click()
		client:typeInPopup("  Molten Core prep  ")
		assert.is_nil(client.popup)
		local board = store(client):current()
		assert.are.equal("Molten Core prep", board.meta.name)
		assert.are.equal(1, #boardRows(client))
		assert.is_true(buttonNamed(client, "New Note").enabled)

		buttonNamed(client, "Rename"):Click()
		assert.are.equal("Molten Core prep", client.popup.editBox.text) -- prefilled
		client.popup.editBox:SetText("BWL prep")
		client:acceptPopup()
		assert.are.equal("BWL prep", board.meta.name)

		buttonNamed(client, "Delete"):Click()
		has(client.popup.text, 'Delete the board "BWL prep" and its 0 notes from this account?')
		client:acceptPopup()
		assert.is_nil(store(client):board(board.id))
		assert.are.equal(0, #boardRows(client))
	end)

	it("keeps the name popup open and warns on a bad name", function()
		local client = openWindow()
		buttonNamed(client, "New"):Click()
		client:typeInPopup("MC|BWL")
		assert.is_not_nil(client.popup)
		has(client.chat[#client.chat], "Board names are 1-64 bytes")
		client.popup.editBox:SetText("MC")
		client:acceptPopup()
		assert.is_nil(client.popup)
		assert.are.equal("MC", store(client):current().meta.name)
	end)

	it("switches boards from the list", function()
		local client = openWindow()
		client:slash("/cork create MC")
		client:slash("/cork add in MC")
		client:slash("/cork create BWL")
		assert.are.same({}, cardTexts(client))
		local rows = boardRows(client)
		assert.are.equal(2, #rows)
		assert.are.equal("BWL", rows[1].name.text) -- sorted by name
		rows[2]:Click()
		assert.are.equal("MC", store(client):current().meta.name)
		assert.are.same({ "in MC" }, cardTexts(client))
	end)

	it("selects the first board when none is selected", function()
		local client = Client.new():login()
		client:slash("/cork create MC")
		client:slash("/cork deleteboard MC")
		client:slash("/cork create AQ")
		store(client).db.char.current = nil
		client:slash("/cork")
		assert.are.equal("AQ", store(client):current().meta.name)
	end)

	it("lays notes out two to a row, sized to the taller card", function()
		local client = openWindow()
		client:slash("/cork create MC")
		client:slash("/cork add short")
		client:slash("/cork add " .. ("long "):rep(80))
		client:slash("/cork add third")
		assert.are.equal(3, #cards(client))
		local rows = {}
		for _, frame in ipairs(client.frames) do
			if frame.template == "WowScrollBoxList" and frame.elements then
				for _, row in ipairs(frame.elements) do
					if row.cards and row:IsVisible() then
						rows[#rows + 1] = row
					end
				end
			end
		end
		assert.are.equal(2, #rows)
		assert.is_true(rows[1].extent > rows[2].extent)
		assert.are.equal(72, rows[2].extent) -- the minimum card, plus the gap
	end)

	it("filters notes with the search box", function()
		local client = openWindow()
		client:slash("/cork create MC")
		client:slash("/cork add Need 4x " .. LINK)
		client:slash("/cork add Repair before you zone in")
		local search
		for _, frame in ipairs(client.frames) do
			if frame.template == "SearchBoxTemplate" then
				search = frame
			end
		end
		search:SetText("fiery")
		assert.are.same({ "Need 4x " .. LINK }, cardTexts(client))
		search:SetText("nothing like this")
		assert.are.same({}, cardTexts(client))
		search:SetText("")
		assert.are.equal(2, #cards(client))
	end)

	it("shows link tooltips and passes clicks to SetItemRef", function()
		local client = openWindow()
		client:slash("/cork create MC")
		client:slash("/cork add Need 4x " .. LINK)
		local card = cards(client)[1]
		local link = "item:17010::::::::60:::::::::"
		card:Run("OnHyperlinkEnter", link, "[Fiery Core]")
		assert.are.equal(link, client.env.GameTooltip.link)
		assert.are.equal(card, client.env.GameTooltip.owner)
		card:Run("OnHyperlinkEnter", "journal:0:123", "[Ragnaros]") -- a type this tooltip can't show
		assert.is_false(client.env.GameTooltip:IsShown())
		card:Run("OnHyperlinkClick", link, "[Fiery Core]", "LeftButton")
		assert.are.same({ link = link, text = "[Fiery Core]", button = "LeftButton" }, client.itemRefs[1])
		client:check()
	end)

	it("shows Edit and Delete on hover", function()
		local client = openWindow()
		client:slash("/cork create MC")
		client:slash("/cork add x")
		local card = cards(client)[1]
		assert.is_false(card.edit:IsShown())
		card:Run("OnEnter")
		assert.is_true(card.edit:IsShown())
		assert.is_true(card.delete:IsShown())
		assert.is_false(card.age:IsShown())
		card:Run("OnLeave")
		assert.is_false(card.edit:IsShown())
		assert.is_true(card.age:IsShown())
	end)

	it("deletes a note after confirming", function()
		local client = openWindow()
		client:slash("/cork create MC")
		client:slash("/cork add doomed")
		local card = cards(client)[1]
		card:Run("OnEnter")
		card.delete:Click()
		has(client.popup.text, "Delete this note?")
		client:acceptPopup()
		assert.are.same({}, cardTexts(client))
		assert.is_true(store(client):current().notes[card.noteId].deleted)
	end)

	it("keeps card ages current while open", function()
		local client = openWindow()
		assert.are.equal(1, #client.tickers)
		assert.are.equal(30, client.tickers[1].seconds)
		client:slash("/cork create MC")
		client:slash("/cork add x")
		assert.are.equal("now", cards(client)[1].age.text)
		client:advance(660) -- the note's rev is a couple of seconds ahead: board creation used two
		client.tickers[1].fn()
		assert.are.equal("10m", cards(client)[1].age.text)
		client:slash("/cork")
		assert.is_true(client.tickers[1].cancelled)
	end)
end)

describe("the note editor", function()
	local client
	before_each(function()
		client = openWindow()
		client:slash("/cork create MC")
	end)

	local function editor()
		return client.env.CorkboardEditor
	end

	it("adds a note with a shift-clicked link and a tag", function()
		buttonNamed(client, "New Note"):Click()
		assert.is_true(editor():IsShown())
		assert.are.equal("New Note", editor().title)
		assert.is_false(buttonNamed(client, "Save").enabled) -- nothing written yet
		local edit = editorText(client)
		assert.is_true(edit:HasFocus())
		edit:Insert("Need 4x ")
		client:shiftClick(LINK)
		assert.are.equal("Need 4x " .. LINK, edit.text)
		assert.is_true(buttonNamed(client, "Save").enabled)

		-- Tag 3 (green), picked from the swatches.
		local swatches = {}
		for _, frame in ipairs(client.frames) do
			if frame.kind == "Button" and frame.parent == editor() and frame.ring then
				swatches[#swatches + 1] = frame
			end
		end
		assert.are.equal(5, #swatches)
		swatches[3]:Click()
		assert.is_true(swatches[3].ring:IsShown())
		assert.is_false(swatches[1].ring:IsShown())

		buttonNamed(client, "Save"):Click()
		assert.is_false(editor():IsShown())
		local note = client.ns.Store.notes(store(client):current())[1]
		assert.are.equal("Need 4x " .. LINK, note.text)
		assert.are.equal(3, note.color)
		assert.are.same({ "Need 4x " .. LINK }, cardTexts(client))
	end)

	it("only takes shift-clicks while it has the focus", function()
		buttonNamed(client, "New Note"):Click()
		local edit = editorText(client)
		edit:ClearFocus()
		client:shiftClick(LINK)
		assert.are.equal("", edit.text)
	end)

	it("takes an item dropped on it", function()
		buttonNamed(client, "New Note"):Click()
		client.cursor = LINK
		editorText(client):Run("OnReceiveDrag")
		assert.are.equal(LINK, editorText(client).text)
		assert.is_nil(client.cursor)
	end)

	it("won't save text a peer would drop, and says why", function()
		buttonNamed(client, "New Note"):Click()
		local edit = editorText(client)
		edit:SetText("|TInterface\\Icons\\Spell_Nature_Polymorph:0|t sheep")
		assert.is_false(buttonNamed(client, "Save").enabled)
		has(labels(editor()), "not textures, icons")
		edit:SetText(("x"):rep(2001))
		assert.is_false(buttonNamed(client, "Save").enabled)
		has(labels(editor()), "2001 / 2000")
		has(labels(editor()), "Notes are limited to 2000 bytes")
		edit:SetText("fine")
		assert.is_true(buttonNamed(client, "Save").enabled)
		has(labels(editor()), "4 / 2000")
		assert.is_nil(labels(editor()):find("limited", 1, true))
	end)

	it("edits a note from its card, keeping an unchanged save free", function()
		client:slash("/cork add first")
		local card = cards(client)[1]
		local before = store(client):current().notes[card.noteId]
		card:Run("OnEnter")
		card.edit:Click()
		assert.are.equal("Edit Note", editor().title)
		assert.are.equal("first", editorText(client).text)
		assert.is_true(buttonNamed(client, "Delete").enabled)

		buttonNamed(client, "Save"):Click() -- nothing changed
		assert.are.equal(before, store(client):current().notes[card.noteId])

		card:Run("OnEnter")
		card.edit:Click()
		editorText(client):SetText("second")
		buttonNamed(client, "Save"):Click()
		local after = store(client):current().notes[card.noteId]
		assert.are.equal("second", after.text)
		assert.is_true(after.rev > before.rev)
	end)

	it("deletes the note it's editing", function()
		client:slash("/cork add doomed")
		local card = cards(client)[1]
		card:Run("OnEnter")
		card.edit:Click()
		local deletes = {}
		for _, frame in ipairs(client.frames) do
			if frame.kind == "Button" and frame.text == "Delete" and frame.parent == editor() then
				deletes[#deletes + 1] = frame
			end
		end
		deletes[1]:Click()
		client:acceptPopup()
		assert.is_false(editor():IsShown())
		assert.are.same({}, cardTexts(client))
	end)

	it("says so when the note was deleted while it was open", function()
		client:slash("/cork add doomed")
		local card = cards(client)[1]
		card:Run("OnEnter")
		card.edit:Click()
		client:slash("/cork delete 1")
		editorText(client):SetText("too late")
		buttonNamed(client, "Save"):Click()
		assert.is_true(editor():IsShown())
	end)

	it("closes on Cancel without saving", function()
		buttonNamed(client, "New Note"):Click()
		editorText(client):SetText("never mind")
		buttonNamed(client, "Cancel"):Click()
		assert.is_false(editor():IsShown())
		assert.are.same({}, cardTexts(client))
	end)

	it("closes with the board window", function()
		buttonNamed(client, "New Note"):Click()
		client:slash("/cork")
		assert.is_false(editor():IsShown())
	end)

	it("registers for Escape", function()
		buttonNamed(client, "New Note"):Click()
		assert.are.same({ "CorkboardFrame", "CorkboardEditor" }, client.env.UISpecialFrames)
	end)
end)

describe("UI changes across a /reload", function()
	it("keeps boards and notes made in the window", function()
		local client = openWindow()
		buttonNamed(client, "New"):Click()
		client:typeInPopup("Molten Core prep")
		buttonNamed(client, "New Note"):Click()
		editorText(client):Insert("Need 4x ")
		client:shiftClick(LINK)
		buttonNamed(client, "Save"):Click()
		buttonNamed(client, "New Note"):Click()
		editorText(client):SetText("Summon at the stone")
		buttonNamed(client, "Save"):Click()
		local before = client.env.CorkboardDB.global.boards

		local reloaded = client:reload()
		assert.are.same(before, reloaded.env.CorkboardDB.global.boards)
		reloaded:slash("/cork")
		assert.are.same({ "Need 4x " .. LINK, "Summon at the stone" }, cardTexts(reloaded))
		assert.are.equal("Molten Core prep", reloaded.env.CorkboardFrame and store(reloaded):current().meta.name)
	end)
end)
