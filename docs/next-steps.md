# Status and next steps

The handoff between sessions. Read this after `CLAUDE.md`. Before you finish, update it: move what you finished into "Where things stand" and rewrite "Next steps".

Last updated: 2026-09-27 (tenth session: player notes, an avoid / good-player list per board, on a Players tab).

## Where things stand

On 2026-09-26 Will asked for the remaining work to be built on best assumptions, with a big validation pass later. So this session broke the phase gate on purpose: Phases 2–6 were built before Phase 0 and Phase 1 were checked in game. **Nothing in design.md §12 is ticked.** Every criterion still needs its evidence from the Forever client or the live host. What passes outside the game is noted under each phase in §12.

### What exists

| Part | Where | State |
|---|---|---|
| Spike tooling 01–02 | `spikes/CorkSpike/` | Dropped by Will; kept until removed (next step 7). |
| Spike tooling 03–06 | `spikes/CorkSpike2/`, `spikes/install_probe.py` | Dropped by Will; kept until removed (next step 7). |
| Phase 1: local boards | `addon/Corkboard/` | Built last session; not run in game. |
| Phase 2: invites, channels, live PUTs | `Core/Invite.lua`, `Core/Wire.lua`, `Net.lua`, `UI/Members.lua` | Built; passes between fake clients running the real addon. |
| Phase 3: anti-entropy, debug panel | `Core/Sync.lua`, `UI/Debug.lua` | Built; passes in the simulator (`addon/spec/helpers/sim.lua`). |
| Phase 4: gate, outbox, bulk rule, fuzz corpus | `Core/Gate.lua`, `Core/Outbox.lua`, `shared/test-vectors/sanitise_fuzz.json` | Built; passes in simulation and between fake clients. |
| Phase 5: Python core | `shared/python/corkcore` | Passes every shared vector plus Hypothesis properties. |
| Phase 5: sync API | `api/` | Passes pytest; the real server answered curl here. Image not built here (no Docker daemon); CI builds it. |
| Phase 5: companion | `companion/`, `addon/Corkboard_Cloud/` | Passes pytest, including the real addon loading the `Data.lua` it writes. |
| Phase 5: hosting | `infra/` | Compose, Caddyfile and `infra/README.md`; not deployed. |
| Professions tab (§9.2) | `Core/Recipes.lua`, `Store:learned`/`shareRecipes`, `UI/Professions.lua`, the scan in `Corkboard.lua` | Built; passes between fake clients. Not run in game. |
| Player notes (§9.4) | `Core/Players.lua`, `Store:addPlayer`/`editPlayer`, `UI/Players.lua`, `UI/PlayerEditor.lua`, the tooltip and group check in `Corkboard.lua` | Built; passes between fake clients. Not run in game. |
| Phase 6: packaging | `tools/package_addon.py`, `.pkgmeta`, `.github/workflows/release.yml`, `companion/corkboard-companion.spec`, `companion/corkboard_companion/gui.py` | Zip builder tested; the GUI, PyInstaller build and store uploads are untested. |
| CI | `.github/workflows/ci.yml`, `api-image.yml` | Green on the branch: luacheck, busted, coverage gate (≥ 95%), spike smoke tests, pytest for corkcore, API, companion and packaging, and a check that the fuzz corpus is current. |

Tests: `busted` runs 681 (Core coverage 98.5%, merge core 100%; the coverage run skips `#slow` specs); pytest runs 142 (corkcore), 22 (API), 32 (companion) and 5 (packaging, `tools/tests`).

### First in-game run (fourth session)

Will installed the addon and CorkSpike in the 1.60.1 beta (build 70009) and ran part of spike 01/02 before deciding **not to do the spike testing**: from here we patch and test the main addon directly. Nothing from the spikes is a prerequisite any more.

- **Fixed: every send failed.** The client's Lua raises "Division by zero" (stock Lua returns inf), and LibSerialize v1.2.2 checks for negative zero with `1 / num`, so any envelope holding a `0` threw. Patched in `Libs/LibSerialize` (listed in `Libs/README.md`); `wire_spec` fails if a re-vendor brings it back. New §2 row in design.md.
- **Fixed: "Error loading Corkboard_Cloud/Data.lua".** The folder was copied from the repo, where `Data.lua` is gitignored. `python tools/package_addon.py --install "<beta>/Interface/AddOns"` now builds the zip and unzips it there (keeping a companion-written `Data.lua`); use it for every re-install.
- **Gate:** spike 01 showed `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()` is **true while idle** with sends succeeding, and `InChatMessagingLockdown()` false. `Gate.CHECKS` is now `InChatMessagingLockdown` only.
- **Own echoes:** CorkSpike failed to recognise its own whispers by exact `Name-Realm` (every arrival counted as "peer1"; the realm is "Classic Beta PvP 2"). Corkboard's echo check in `Net.lua` now ignores case and the realm's spaces, hyphens and apostrophes, and logs `? X shares our name (we are Y)` once to the debug panel if a same-named sender still gets through. If that line shows up, it's the echo: fix `nameKey` from what it prints.
- **Fixed: Forever names have surnames.** `UnitFullName("player")` returns `"Aprune", "Proudshield"` (the surname where the realm goes), so the addon called itself `Aprune-Proudshield` while CHAT_MSG_ADDON names it `Aprune Proudshield-ClassicBetaPvP2`. Its own echo showed as "Synced with Aprune Proudshield-…" and a phantom member. `identity()` now uses `GetPlayerInfoByGUID` (whole name, empty realm for our own) plus `GetNormalizedRealmName()`; the fake client mimics Forever's names and `net_spec` covers it. Boards made before the fix have the old name as owner and author: recreate them.
- **Cloud sync works locally:** API on `127.0.0.1:8000`, companion `setup` then `watch`; first sync pushed 4 and pulled 3, and the addon showed "Cloud 1m ago". Next is deploying the API so a second player can reach it.
- `addon_spec` now reads TOCs with CRLF normalised, so `busted` passes on a Windows checkout. Lua tests run in WSL Ubuntu here (`apt install lua5.1 lua-busted lua-check lua-dkjson`).

### Sixth session: QOL and the gear feed

- **Note editor:** clicking anywhere in the text box now focuses it with the cursor at the end (`UI/Editor.lua`). Before, only the line holding text took the click.
- **Probes Will ran in game (1.60.1):** `CombatLogGetCurrentEventInfo` is nil and registering `COMBAT_LOG_EVENT_UNFILTERED` is blocked ("only available to the Blizzard UI"), so a crit leaderboard can't be built; dropped. `PLAYER_EQUIPMENT_CHANGED` plus `GetInventoryItemLink` give a plain link and quality. Both are new §2 rows. A screenshot-pasting idea was also dropped (addons can't read the clipboard or show new images).
- **Gear feed (design.md §9.1):** a rare-or-better item a character equips for the first time is posted to the **Gear** tab of every board with the option on (local, on by default, checkbox on the Gear tab). An entry is a Note with `kind = "gear"`, so it syncs over every existing path. The merge core learned `kind` in Lua and Python (sanitiser reason `kind`, tie-break after `deleted`), with new shared vectors and `kind` in both property-test generators. The API has a `kind` column and upgrades older databases in place. Tests: `addon/spec/gear_spec.lua` (store rules, two fake clients, the tab, `/reload`), `api/tests/test_api.py`, and the companion's addon-loads-Data.lua test.

### Seventh session: the minimap button

- **LibDBIcon-1.0 minor 55** is vendored in `Libs/LibDBIcon-1.0/`, copied unmodified from Details! Damage Meter's repo because the WowAce SVN is blocked here (source in `Libs/README.md`). The TOC loads it after LibDataBroker.
- `Corkboard.lua` registers the launcher as a minimap button; its angle and hidden state live in `CorkboardDB.global.minimap`. `/cork minimap` hides or shows it. `ui_spec` covers the rim position, the click, hiding and a dragged angle across `/reload`; the fake client gained `Minimap`, `SetPoint` recording and animation groups.

### Eighth session: profession probes and the Professions tab

Will asked whether a Professions tab could share the recipes each member knows. Four rounds of `/dump` on a Leatherworking character (1.60.1) found the following, now two §2 rows:

- **The retail API, window open only.** `C_TradeSkillUI.GetAllRecipeIDs()` gave 592 ids (the whole catalogue), 8 of them `learned` at skill 47/75; the first was `1263079` ("Sewing Machine", item 279945). `GetBaseProfessionInfo()` gave Leatherworking, `professionID` 165, 47/75. With the window closed every call is empty or zero and `IsTradeSkillReady()` is false. `GetNumTradeSkills` and `GetNumCrafts` are nil, so Enchanting has no separate craft API. The window is `ProfessionsFrame`.
- **Profession links exist.** `GetTradeSkillListLink()` returned `|cffffd000|Htrade:Player-4613-00CD2154:2108:165|h[Leatherworking]|h|r` and `2108`. The sanitiser rejects `trade` links.
- **Recipe links aren't secret.** `GetRecipeLink(1263079)` returned a plain 65-byte string (`issecretvalue` false). An earlier `gsub("|","||")` on it counted 0 pipes, most likely because the chat box escapes a typed `|` before `/run` sees it: in-game probes should use `string.char(124)` or a pattern without `|`. The type is Classic's `enchant` (confirmed with `:match("H(%a+):")`): `|cffffd000|Henchant:1263079|h[Leatherworking: Sewing Machine]|h|r`, 65 bytes. The sanitiser rejects it, so a shift-clicked recipe can't go in a note today.
- **Sizes for the design:** 7-digit ids cost 8 bytes each in a comma list, so a 2,000-byte note holds about 245; base-36 (4 characters) holds about 400.

Will then said to build the searchable version (design.md §9.2):

- **Links:** the sanitiser accepts `enchant` and `trade` links (Lua, Python, shared vectors; the fuzz corpus is unchanged), so a shift-clicked recipe or profession can go in any note.
- **Records:** a Note with `kind = "recipes"` per character and profession, text `R1;<id>;<skill>;<max>;<learned>;<name>` plus the learned recipe ids ascending as base-36 gaps (`Core/Recipes.lua`). New sanitise and merge vectors, and `recipes` in both property-test generators.
- **Scanning** (`Corkboard.lua`): a scan is wanted on `TRADE_SKILL_SHOW`, `TRADE_SKILL_DATA_SOURCE_CHANGED` and `NEW_RECIPE_LEARNED`, and runs once `IsTradeSkillReady()`; crafting alone never resends. Linked, guild and NPC views are skipped.
- **Sharing** (`Store`): the last scan per profession is kept in `CorkboardDB.char.professions` and shared to every board with `recipes ~= false`, at login, after a scan, and when a board is created or has the option ticked. A board joined from an invite waits until it has synced once (`sync.joined` with no `lastPeerAt` or `lastCloudAt` yet; Sync calls `env.synced` when it matches a peer), so a rejoin can't reuse an old note id. Unticking deletes this character's lists on that board.
- **Tab:** fourth tab, **Professions**: per-member professions with skill and count, or with a search, matching recipes as `enchant` links named by `C_Spell.GetSpellName` (fallback `GetSpellInfo`) with who knows each.
- **Bulk rule:** `Sync.noteBytes` prices a note at 150 bytes or its text length, whichever is larger, and the responder sums its own bytes per mismatched bucket (§5.6).
- **Tests:** `addon/spec/recipes_spec.lua` (encoding, rows, store rules, the bulk rule in the simulator, and two fake clients with a fake profession window); `ui_spec` now picks the window's own search box.

### Ninth session: quest logs (design.md §9.3)

Will asked for a way to answer "what quests are you on?", with a mark on quests you share.

- **Records.** Each character's quest log is one Note with `kind = "quests"` at id `<prefix>-0`, a counter `Store.nextNoteId` never hands out, so it can't overwrite a real note and every install of the character writes the same record. The text is `id:level` pairs (about 400 bytes for Forever's 40-quest log; full links would pass the 2,000-byte limit). Titles come from each client's own quest data. The sanitiser accepts `"quests"` in Lua and Python; new sanitise and merge vectors (including counter 0 as an id), `"quests"` in both property generators, and an API round trip.
- **Detection** (`Corkboard.lua`): quest events schedule one read 2 s later; nothing is read before the session's first `QUEST_LOG_UPDATE`, and an unchanged log sends nothing. Sharing is per board, local and **on by default** (like gear); unticking deletes the log, and ticking again writes a newer version over the tombstone.
- **UI:** a fifth tab, **Quests** (`UI/Quests.lua`): members sharing a log on the left, the chosen member's quests on the right by level, with a ready-check tick on quests you're on too, "online now" or "as of 2h ago", and an "Only quests I'm on too" filter. Clicking a member on the Members tab opens their log. `/cork quests [name]` and `/cork quests on|off` do the same from chat.
- **Not seen in game yet:** the quest log API names (`C_QuestLog.GetInfo` and friends) are assumptions, recorded as such in design.md §2. The check is next step 4 below. Tests: `addon/spec/quests_spec.lua` (store rules, the view, the command, two fake clients with quest logs, title loading, the tab, the Members click and `/reload`).

### Tenth session: player notes (design.md §9.4)

Will asked for a blacklist / whitelist area on a board: put in a character's name, a short explanation of what they did, and whether to avoid them or they're a good player.

- **Records.** An entry is a Note with `kind = "player"` and text `P1;<avoid|good>;<name>` then the reason on the following lines (links allowed), so it rides every sync path unchanged. The sanitiser accepts `"player"` in Lua and Python; new sanitise vectors (including a texture in the reason still failing), a merge vector ("quests" beats "player" on an exact tie), `"player"` in both property generators, and an API round trip. The fuzz corpus is unchanged.
- **Core** (`Core/Players.lua`, pure): encode/decode, name tidying, matching on the first name (Forever surnames and realms vary between units, chat and typing), `entries`, `index` and `lookup`. `Store:addPlayer` and `editPlayer` (an unchanged save writes nothing); delete is `Store:deleteNote`. `/cork player <name>` lists what every board says about someone.
- **UI:** a sixth tab, **Players** (`UI/Players.lua`): Avoid / Good players filters, search, Add Player, and rows with a ready-check cross or tick, the name and verdict in the game's red or green, author and age, the reason with live links, and Edit / Delete on hover. The editor (`UI/PlayerEditor.lua`) has Character (with a Target button, pre-filled from the target), Avoid or Good player, and Why.
- **In the world** (`Corkboard.lua`): hovering a player adds the boards' verdicts to their tooltip (`TooltipDataProcessor`, falling back to `OnTooltipSetUnit`), and an avoided player joining your group prints one warning per session. Both use every board on the account and skip secret names. These APIs are assumptions until seen in game (new §2 row); the check is next step 5.
- **Tests:** `addon/spec/players_spec.lua` (codec, store rules, lookup, the view, the command, and two fake clients adding, syncing, editing and deleting from the tab, the tooltip, the group warning and `/reload`). The fake client gained other units, groups, `GROUP_ROSTER_UPDATE`, unit tooltips and `TooltipDataProcessor`.

### Spec changes (earlier sessions)

Each is written into `docs/design.md` with its reason:

- **§5.1:** the channel name is `Cork` + `%08x` of FNV1a32(`id|secret`), so a rotation moves the board to a fresh channel. Guild boards use GUILD instead of a channel. Replies ride the board's transport with a `to` field; nothing whispers.
- **§5.2:** Corkboard frames its own chunks over ChatThrottleLib (index and count bytes) instead of AceComm. The secret-value check must run before anything reads the payload, and AceComm can't detect a missing middle chunk.
- **§5.3:** HELLO fields spelled out (nonce, per-bucket counts, members digest, the sender's own member record). META and MEMBERS go out when a HELLO shows the sender is behind, with suppression.
- **§5.4:** responders wait in a ranked order instead of a uniform 0.5–3 s. In the simulator the uniform delay gave exactly one IDX in only 87% (low latency) and 54% (higher latency) of HELLOs, against the 90% target; ranked gives 100%.
- **§5.5, §5.6:** the gate's candidate checks, the outbox budget (8 tokens, 0.9/s), the responder estimates the bulk transfer, and "cloud-enabled" means the companion synced the board in the last 7 days.
- **§7.1, §7.2:** the companion pushes whatever the server lacks (not `rev > lastPushedClock`), registers and rotates as needed, and `CorkboardCloudData`'s format.
- **§14:** new questions 6 (re-sharing after a rotation) and 7 (tombstones against the 1,000-row cap).

### Audit cuts (third session)

A pass for over-engineering (the `ponytail-audit` checklist), applied in full:

- **§13:** AceAddon, AceConsole, AceEvent, AceTimer and AceComm are gone. `Corkboard.lua` loads on its own frame (`ADDON_LOADED`, `PLAYER_LOGIN`) and registers `/cork` through `SlashCmdList`; ChatThrottleLib now sits in `Libs/ChatThrottleLib/`. The addon table is the global `Corkboard`, which is how CorkSpike2 finds the sanitiser now that `AceAddon:GetAddon` is gone.
- **§9:** the Phase 1 store commands (`/cork create`, `add`, `list`, `edit`, …) and `Store.findBoard`, `noteRef` and `findNote` are gone. Specs use `Client:createBoard`, `addNote`, `editNote`, `deleteNote` and `noteTexts` in `helpers/client.lua`.
- Smaller cuts: one `Main.Button` for the UI, one `newBoard` in the store, one `Sync:scheduleOnce`, one `plural` and age formatter in `Commands`, `Invite.encode` in place of `Store.invite`, and unread state removed (`Net.Channels`, `Sync.nonces`, `Outbox.lastResult`, `Reassembler.dropped`, the send result code). The API reads only `CORK_DB` and `CORK_TRUSTED_PROXY` from the environment.

## Settled and accepted

On 2026-09-26, after the first in-game smoke test, Will said he's happy with where everything is, so the open items were closed out rather than left as unknowns.

- **Settled in game (1.60.1, build 70009):** the gate check is `C_ChatInfo.InChatMessagingLockdown` only (`Gate.CHECKS`); `Enum.SendAddonMessageResult` has `AddonMessageThrottle=3`, `ChannelThrottle=8`, `AddOnMessageLockdown=11` (`Gate:classify`); WHISPER bursts of 40, and ~56/s sustained, all returned Success, so the outbox's 8 tokens at 0.9/s is conservative (`Outbox.BURST/RATE`); Forever names carry surnames (`identity()` in `Corkboard.lua`); cloud sync works end to end against a local API.
- **Design accepted as built:** every former design question is now a decision in design.md §14. In short: rotation moves the board to a new channel and the owner re-shares by hand; nothing whispers; guild boards are invite-only and use GUILD instead of a channel; channel slots go to the current board, then the most recently selected; a member counts as online for 13 minutes after any message; any member edits or deletes any note, and only the owner removes members or rotates (UI and `/cork` only); removed members are ignored until they rejoin with a fresh invite; "cloud-enabled" means the companion synced the board in the last 7 days; the bulk rule estimates 150 bytes a note, and a partial catch-up sends the newest 20; one shared `corkcore` package; the cloud and guild options live on the Members tab; the API rate-limits per board before checking the secret.
- **Out of scope for v1:** the BNet transport, closing a board for everyone, tombstone collection, and whispering new invites after a rotation.

### What the in-game checks exercise

Not open questions, just code paths the checklists below run in the client for the first time. If one misbehaves, the fix lives where it says.

- Window, templates and popups: `UI/Main.lua`, `UI/Popups.lua`, `UI/Members.lua`, `UI/Debug.lua`, `UI/Quests.lua`, `UI/Players.lua`, `UI/PlayerEditor.lua`.
- The unit tooltip hook, other players' names and the group roster: `WatchPlayers`, `UnitPlayerName` and `CheckGroup` in `Corkboard.lua`.
- The quest log API and quest title loading: `readQuestLog` and `Corkboard:QuestTitle` in `Corkboard.lua`.
- Hidden password channels (join, hiding from chat frames, the wrong-password notice, sender names): `Net.lua`.
- Link insertion and link round trips: `UI/Links.lua`, `Core/Sanitise.lua`.
- The live client's folder name at launch: `companion/corkboard_companion/discover.py` lets the player pick if it guesses wrong.
- The Social pane's Channels list may still show a board's channel; "never shows" covers chat frames only.

### Still to do before release

- **Deploy:** the `corkboard` Arcane project doesn't exist yet. `tools/arcane_deploy.py create --domain …` makes it from a tailnet machine; it needs the public hostname, DNS pointing at the host and ports 80/443 forwarded. The backup service installs sqlite with `apk` at start, so it needs network access.
- **Companion:** the tkinter window and the PyInstaller build need a run on Windows and macOS; there's no code-signing certificate yet.
- **Stores:** CurseForge and Wago need project IDs in the TOCs, tokens as secrets, and a Forever listing. Until then releases are GitHub-only.
- **Libraries:** a licence check on LibDataBroker-1.1 and LibDBIcon-1.0 before publishing, and LibDBIcon from its WowAce release in place of the Details copy.

## Next steps

Do these in order unless Will says otherwise.

1. **Will: the Phase 1 check.** Install with `python tools/package_addon.py --install "C:/wow/World of Warcraft/_classic_beta_/Interface/AddOns"`. Then:
   1. `/console scriptErrors 1`, then `/cork`. Click **New**, name the board `Molten Core prep`.
   2. **New Note**: type `Need 4x `, shift-click an item in your bags, pick the blue tag, Save. Add `Bring fire resistance` and a note long enough to wrap.
   3. Hover the item link (tooltip), click it (item pops up), hover a card (Edit and Delete replace the age).
   4. Edit the second note, delete the third, search `fire`, then clear the search. Try saving `|T`: Save stays greyed with a yellow message.
   5. Make a second board, rename it, select the first again. `/reload`, `/cork`: everything is still there.
   6. Escape closes the editor, then the window; the window drags; the addon compartment lists Corkboard.
   7. The minimap button (a note icon on the rim) shows a tooltip, opens the window and drags round the rim. `/cork minimap` hides it; `/reload` keeps it hidden and keeps its dragged spot once shown again.
2. **Will: the gear feed check.** One character is enough; a second on the same board also checks that entries sync:
   1. Equip a blue or purple item you haven't worn on that character since installing: the **Gear** tab on both clients shows "Name equipped [item]" within a few seconds, and hovering the link shows its tooltip.
   2. Swap it off and on again, and equip a green: nothing new appears.
   3. Untick "Post my new rare and epic gear to this board", equip another new blue: it doesn't appear on that board. `/reload`: the tick state and the feed are unchanged.
   4. Send any Lua errors. If nothing posts, run `/dump GetInventoryItemQuality("player", 1)` with a helmet on and send the output.
3. **Will: the Professions tab check** (can go with step 2; a second character on the board also checks syncing):
   1. Open a profession window, then the **Professions** tab: a row like "Leatherworking 47/75 · 8 recipes" with your name. The count should match the recipes you know.
   2. Search `sewing` (or any recipe you know): the recipe shows as a gold link with your name. Hover it (recipe tooltip) and click it. If the name reads "Recipe 1263079", `C_Spell.GetSpellName` doesn't name recipes: send `/dump C_Spell.GetSpellName(1263079), GetSpellInfo(1263079)`.
   3. Craft something that skills up: nothing resends (`/cork debug` shows no PUT). Close and reopen the window: the skill updates.
   4. Untick "Share my recipes on this board": the row goes on the other client. Tick it again: it's back without reopening the window. `/reload` keeps it.
   5. Shift-click a recipe and your `[Leatherworking]` link (the link button in the profession window) into a note: Save is allowed, and the other client shows both. Click the `[Leatherworking]` link on the other client, with you online and then logged out, and note what opens.
   6. Send Lua errors. Pruning a dropped profession waits on `/dump GetProfessions()` and `/dump GetProfessionInfo(<each index>)` output from a character with two professions and Cooking.
4. **Will: the quest log check.** Two characters on one board (two accounts, or a friend):
   1. On A, `/dump C_QuestLog.GetNumQuestLogEntries()` and `/dump C_QuestLog.GetInfo(2)`: send the output. If `C_QuestLog.GetInfo` is nil, `/dump GetQuestLogTitle(2)` instead.
   2. Open `/cork`, **Quests** tab, on both. Within a few seconds of login each sees the other in the list on the left, with the right quest count.
   3. On B, pick A: A's quests are listed by level with the right names (a quest B has never seen may show "Quest #id" for a moment). Hover one: its tooltip shows. Quests both have are ticked, and "Only quests I'm on too" leaves just those.
   4. A accepts a quest, then abandons another: B's list follows within about 5 s. Killing a mob for an objective sends nothing (`/cork debug` shows no PUT).
   5. A unticks "Share my quest log with this board": A disappears from B's list. A ticks it again: A is back.
   6. On B, `/cork quests` and `/cork quests <A's first name>` in chat. On the Members tab, clicking A opens A's log.
   7. `/reload` on A: nothing changes on B, and A's list isn't briefly empty. Send any Lua errors and a screenshot of the tab.
5. **Will: the player notes check.** Two characters on one board, plus a third player (anyone) to target:
   1. On A, target the third player, open `/cork`, **Players** tab, **Add Player**: the Character box already holds their name. Pick **Avoid**, write a reason with a shift-clicked item, Save. The row shows a red cross, the name, "Avoid" in red, the reason with a working item link, and "You · now" or your name.
   2. On B within a few seconds: the same row. Hover it: Edit and Delete appear. Edit it to **Good player**; A's row turns green.
   3. Mouse over the third player (on A and B): their tooltip has a "Corkboard: Good player" line with "author · board" and the reason. Change it back to Avoid: the tooltip follows. If no line shows, send `/dump TooltipDataProcessor ~= nil` and `/dump GetPlayerInfoByGUID(UnitGUID("target"))` with them targeted.
   4. Invite the third player to a party on B: chat prints "… is in your group. Avoid: …" once. Leave and re-invite: it prints again.
   5. `/cork player <their name>`, then the same with a different case, and with their realm added: the same lines each time.
   6. Untick **Good players**, then search a word from the reason; Delete the entry (the popup reads "Delete this player note?") and it goes on both. `/reload` on A keeps everything. Send Lua errors and a screenshot of the tab and the tooltip.
6. **Will: the Phase 2–4 check.** Needs two clients: two accounts, or a friend.
   1. On A: open the **Members** tab, click the invite box, Ctrl+C, and send it to B out of game. On B: **Join**, paste. Within about 15 s B shows the board's name and A's notes, and once the catch-up finishes the status line reads "Synced with A …".
   2. On both: nothing in any chat tab mentions a `Cork…` channel, even after `/reload`.
   3. A edits a note: B shows it within 5 s. `/cork debug` on both: the gate is Open, and the log shows the PUT.
   4. A dies (or pulls a dungeon boss) and edits while dead: A's status line says "Paused · N messages queued". After the res, B has the edits within 10 s, with no Lua errors.
   5. B logs out. A makes 20 notes, edits 5 and deletes 3. B logs in: within 60 s both debug panels show the same digest, and B's log shows IDX for only some buckets.
   6. A removes B in the Members tab: B stops getting A's edits. A sends the new invite, B joins with it, and syncing resumes.
   7. Send Lua errors and screenshots of the window, the Members tab, the debug panel and the status line.
7. **Apply the results.** Fix whatever the checks turn up and tick the §12 items that have their evidence. Since the spikes are dropped, `spikes/`, its CI smoke steps and `Corkboard.Sanitise` (kept only for CorkSpike2) can go in their own small change. If the 1.60 client has `C_EncodingUtil`, it could replace LibSerialize and LibDeflate.
8. **Deploy the API:** on Will's box, `$env:ARCANE_API_KEY=…; python tools/arcane_deploy.py create --domain corkboard.<domain>` (`infra/README.md`, full steps in `docs/arcane-next-steps.md`). Then the Phase 5 checks: health over TLS from outside the tailnet, the dashboard unreachable, and a restore drill. Then install the companion (`pip install ./shared/python ./companion`, `corkboard-companion setup --api https://corkboard.<domain>`) and run the "B edits and logs out, A's companion syncs, A reloads" check for real.
9. **Phase 6 for real:** CurseForge and Wago IDs and tokens, a signing certificate, and a Windows/macOS test of the companion's window and PyInstaller build.

## Open issues

- **Note-id collision** is fixed for the common case (§4.2). Two installs of one character that both create notes before either has seen the other's can still produce the same id, and LWW keeps one. Accepted for v1.
- **Board deletion is local-only.** Closing a board for everyone is out of scope for v1 (§14.5).
- **Digest blind spot:** the digest can't see a same-`(rev, editor)` tie with different content (§4.3). Those ties resolve through live `PUT`s or the cloud. Accepted for v1.
- **Tombstones are never collected**, and the API caps a board at 1,000 rows including them. Accepted for v1 (§14.7).
- **LibDataBroker-1.1 and LibDBIcon-1.0 licences.** Neither states one in its files. Check before publishing.

## Environment notes (cloud sessions)

- `luarocks.org` is blocked by the network policy. Use Ubuntu packages instead: `apt-get install -y lua5.1 liblua5.1-0-dev luarocks lua-busted lua-check lua-dkjson`. `luarocks --lua-version=5.1 install luacov` does work, because it installs from a GitHub mirror.
- PyPI works: `pip install -e shared/python -e "api[test]" -e "companion[test]"`. There's no tkinter and no Docker daemon, so the companion's window and the API image can't be tried here.
- `busted` takes about 24 s. The coverage run (`busted --run=coverage && luacov`) takes about 80 s; it skips `property_spec`, `sync_property_spec` and anything tagged `#slow`.
- `git clone https://github.com/...` works through the proxy, but plain HTTPS to github.com pages returns 403, and `repos.wowace.com` (the WowAce SVN) is blocked.
- The only locales available are C and C.UTF-8.
- `addon/spec/helpers/client.lua` is the fake client. It loads the real TOC and libraries, and now runs several clients on one `Client.Network`: password channels, chat frames with message filters, the server throttle, lockdown (`client.locked`), secret values (`client.secrets`), ChatThrottleLib's OnUpdate, and C_Timer. `Client.new({ cloud = … })` also runs a `Corkboard_Cloud/Data.lua`.
- `addon/spec/helpers/sim.lua` is a faster, pure-Lua simulator of several members (store, outbox and sync engine, the real wire format, latency, loss and the throttle), for protocol tests.
- `spikes/mock/wowmock.lua` is a rough fake client for the spike addons only.
