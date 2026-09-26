# 04: Links through the LibDeflate addon-channel round trip

**Status:** not run yet. The tooling is ready in `spikes/CorkSpike2/`.

## Question

- What do item, quest, spell, achievement and currency links look like on Forever? In particular, do item links use named colours (`|cnIQ4:`), which §6 allows just in case?
- Does Corkboard's sanitiser accept every link a player can make? Are there link types it rejects that players will want (`enchant`, `trade`, `talent`, …)?
- Does each link survive LibSerialize → LibDeflate `CompressDeflate` → `EncodeForWoWAddonChannel` → an addon message → the reverse, byte for byte?
- Does `GameTooltip:SetHyperlink` show each kind?
- Which inserter does a shift-click call on Forever: `ChatFrameUtil.InsertLink`, `ChatEdit_InsertLink`, or both? Does it fire when no chat box is open? (Phase 1 in-game check.)

## How it was tested

- Client build, realm, date:
- Steps:
  1. Enable Corkboard as well as CorkSpike2 (CorkSpike2 borrows its libraries and sanitiser).
  2. `/cspike2 capture`, then within 2 minutes shift-click: an item in your bags, an item in chat, a quest in the quest log, a spell in the spellbook, a profession recipe, and a talent. Do some with a chat box open and some without.
  3. `/cspike2 links`, wait for "finished", then `/cspike2 report`.

## Result

_Paste the "Spike 04" part of the report here._

## Design impact

_For example: add a test vector for the real item-link format (`shared/test-vectors/sanitise.json`), change the allowed link types in §6, and fix `UI/Links.lua` if the hook is wrong._
