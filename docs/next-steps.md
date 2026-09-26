# Status and next steps

The handoff between sessions. Read this after `CLAUDE.md`. Before you finish, update it: move what you finished into "Where things stand" and rewrite "Next steps".

Last updated: 2026-09-26.

## Where things stand

### Phase 0: Forever spikes

| Spike | Tooling | Answered |
|---|---|---|
| 01 restriction API and result codes | `spikes/CorkSpike/` (`/cspike all`, `/cspike canary`) | No. Waiting for Will to run it in the beta. |
| 02 throttle | `spikes/CorkSpike/` (`/cspike all`) | No. Waiting for Will to run it in the beta. |
| 03 channel reach and limit | None | No |
| 04 link round trip through LibDeflate | None (LibDeflate is now vendored) | No |
| 05 `BNSendGameData` | Partly: `/cspike bnet` adds BNet to the shared-budget runs | No |
| 06 SavedVariables bug, install folder | None | No |

`docs/spikes/01-send-restriction.md` and `02-throttle.md` are still empty templates, so the 2026-09-26 session skipped step 1. CorkSpike has only run against the mock client in `spikes/mock/`, never in game.

### Phase 1: local boards

- **Done: merge core** in `addon/Corkboard/Core/` (`Util`, `Sanitise`, `Merge`, `Digest`). It's pure Lua 5.1 with no WoW API.
- **Done: libraries.** They're vendored under `addon/Corkboard/Libs/` from their latest release tags: Ace3 r1403, LibSerialize 1.2.2, LibDeflate 1.0.2 and LibDataBroker-1.1. `Libs/README.md` records the sources and commits.
  - **Missing: LibDBIcon-1.0.** Its upstream is WowAce SVN, which the cloud network blocks, and the GitHub mirrors are years stale. Will needs to drop `LibDBIcon-1.0/LibDBIcon-1.0.lua` and `lib.xml` from a current release into `Libs/`. Nothing needs it until the minimap button.
- **Done: skeleton and store** (commit `b38964c`), but **not yet run in game.**
  - `Corkboard.toc` (Interface 16001) loads the libraries, then the Core files in order, then `Corkboard.lua`.
  - `Core/Store.lua` is pure Lua. It keeps boards in `CorkboardDB.global.boards` (account-wide) and the selected board per character. Every change goes through `Merge`.
  - Note ids use the board-derived counter (§4.2).
  - `Core/Commands.lua` is the `/cork` interface: `boards`, `create`, `use`, `rename`, `deleteboard`, `list`, `add`, `edit`, `color` and `delete` (§9).
  - `Corkboard.lua` is the thin WoW wrapper.
- **Done: first UI** (commit `7d8800a`), but **not yet run in game.**
  - `UI/Main.lua` is the board window: board list with New, Rename and Delete; a two-column card grid in a ScrollBox; search; New Note; and a status line.
  - `UI/Editor.lua` is the note editor: multi-line input, byte counter, tag picker, and Delete, Cancel and Save. It won't save text the sanitiser rejects.
  - `UI/Links.lua` handles tooltips, click-through and shift-click insertion. `UI/Popups.lua` has the StaticPopups.
  - The logic behind them is pure Lua in `Core/View.lua`.
  - A blank `/cork` toggles the window. So do the addon compartment and an LDB launcher.
  - `ui-style.md` "Phase 1 build notes" lists where it departs from the mockups: no tabs until Phase 2, Rename and Delete in the board-list footer, and no "No tag" swatch.
- **Tests:** `busted` runs 427 tests. Among them:
  - `addon_spec` loads the real TOC and libraries in a fake client (`addon/spec/helpers/client.lua`), drives `/cork` through the real slash handler, and checks state survives a simulated `/reload`;
  - `ui_spec` clicks through the window and editor in the same fake client, including UI-made changes across a `/reload`. About 95% of the UI code runs in it.
  - `purity_spec` sandboxes all of Core.
  - Line coverage of Core is 99.6%, and the merge core is at 100%. `luacheck .` is clean.
- **Spec changes this session**, each explained in its commit:
  - §4.4 (`ed64eb6`): the digest uses **FNV-1a instead of Adler-32**. Adler-32 collides on revs 81 apart (and 810, 891, …) with the same editor, so anti-entropy would never repair those notes. The convergence property test found it. `fnv1a32.json` replaces `adler32.json`, and `digest.json` was recomputed.
  - §4.1, §4.3, §5.3, §6, §7.3 (`74c9a56`): **BoardMeta**, `{ name, rev, editor }`. The board name is a replicated LWW record so renames sync, with new vectors and property tests.
  - §4.1, §4.2, §9, §14 (`b38964c`): the AceDB layout, local-only board delete, the note-id rule and the `/cork` commands.
- **Not started:** the minimap button (waits for LibDBIcon).

Phase 1 checklist in design.md §12:
- "Coverage ≥ 95% and all vectors pass in Lua": met.
- "Create, rename, delete…, tooltips, click opens": built, and passes in the fake client. It needs Will's in-game check (below).
- "State survives `/reload`": passes in the fake client, for `/cork` and UI changes. It also needs the in-game check.

Nothing is ticked yet.

## Next steps

Do these in order unless Will says otherwise. Keep one step per branch or PR.

1. **Will: check Phase 1 in game.** The fake client only proves the Lua runs; frame templates, ScrollBox, the link hook and the look need the real client.
   1. Close the game. Delete any old `_classic_beta_/Interface/AddOns/Corkboard`. Copy the repo's `addon/Corkboard` folder there (copy it, don't symlink it). Launch, check Corkboard is enabled, log in, and run `/console scriptErrors 1`.
   2. `/cork` opens the window. Click **New**, name the board `Molten Core prep`, and press Enter.
   3. Click **New Note**. Type `Need 4x `, then shift-click an item in your bags; the link should appear in the editor. Pick the blue tag and Save. Add two more notes: `Bring fire resistance` and one long enough to wrap several lines.
   4. Hover the item link on its card: the item tooltip should show. Click it: the item pops up like a chat link. Hover a card: Edit and Delete replace its age.
   5. Edit the second note to `Bring fire resistance gear` and Save. Delete the third, confirming the popup. Type `fire` in Search, check only the matching note shows, then clear it.
   6. Try to save `|T` in a new note: Save should stay greyed, with a yellow message. Cancel.
   7. Click **New** again and make `Scratch`; click **Rename** to call it `Scratch board`; select `Molten Core prep` in the list.
   8. `/reload`, then `/cork`. Both boards and both remaining notes (with links, tag and edit) should be there. `/cork list` should agree.
   9. Also check: Escape closes the editor, then the window; the window drags; the addon compartment (the minimap dropdown) lists Corkboard, if Forever has one.

   Send a screenshot of the window and the editor, and any Lua errors. Things most likely to need fixing, because they couldn't be checked here:
   - whether `ChatFrameUtil.InsertLink` or `ChatEdit_InsertLink` is what Forever calls on shift-click;
   - quest-log shift-clicks only link while a chat box is open (the same limit AceGUI has);
   - the ScrollBox calls (`CreateScrollBoxListLinearView`, `SetElementInitializer("Button", …)`, `MinimalScrollBar`);
   - `PortraitFrameTemplate`'s `SetTitle` and `SetPortraitToAsset`;
   - the StaticPopup edit box field name;
   - text measurement for card heights.

   Tick the Phase 1 items in design.md §12 once this passes.
2. **Process the spike 01/02 results** once Will has pasted them into `docs/spikes/`.
   - Fill in "Design impact".
   - Update `docs/design.md`: the real restriction-check name and restricted result code (§5.5), and the measured throttle (§2, §5.6, and the §11 simulator's burst).
   - If the report shows CorkSpike misbehaving on the real client, fix it. Re-check with `lua5.1 spikes/mock/smoke.lua spikes/CorkSpike/CorkSpike.lua`.
3. **Vendor LibDBIcon-1.0** once Will supplies a current build (see above). Add it to the TOC after LibDataBroker, and to the library list in `addon_spec`.
4. **Phase 1 fixes from Will's in-game check** (step 1), then the minimap button once step 3 is done: register the existing LDB launcher (`Corkboard.launcher`) with LibDBIcon, saving its position in `CorkboardDB.global`.
5. **Spike tooling for 03–06.** This can run alongside steps 3 and 4.
   - Spike 04 can now use the vendored LibDeflate.
   - Spike 05 can extend `/cspike bnet` with payload-size cases.
6. **CI:** a GitHub Actions workflow that runs `luacheck .`, `busted`, and the coverage run.
7. **Later, in Phase 5:** Python ports of the merge core in `api/` and `companion/`. They must pass every file in `shared/test-vectors/`, including `fnv1a32.json`, the BoardMeta cases (`board_name`, `meta` and merge `meta[]`), and Hypothesis property tests (§11). The companion reads `CorkboardDB.global.boards`.

## Open issues

- **Note-id collision** is fixed for the common case (§4.2). Two installs of one character that both create notes before either has seen the other's can still produce the same id, and LWW keeps one. That's accepted for v1.
- **Board deletion is local-only.** Closing a board for everyone is §14 question 5.
- **Digest cost.** `Digest.compute` takes about 20 ms for a 1,000-note board under PUC Lua 5.1. That's fine for a HELLO every 5 minutes, but Phase 3 should cache bucket hashes and recompute only the buckets a change touches.
- **Named colours.** The sanitiser allows `|cnNAME:` colours such as `|cnIQ4:`, in case Forever's item links use them. Spike 04 confirms. Add a vector for whatever link format it finds.
- **Digest blind spot** (a separate issue from the Adler-32 one): the digest can't see a same-`(rev, editor)` tie with different content (§4.3). Those ties resolve through live `PUT`s or the cloud. That's acceptable for v1, but keep it in mind for the Phase 3 tests. BoardMeta isn't in the digest at all; it rides on every HELLO (§5.3).
- **LibDataBroker-1.1 licence.** Its repository states none. Check before the Phase 6 packaging.
- **Hosting questions.** §14 questions 1–4 are still open (reverse proxy, tunnel, delete permissions, guild boards).

## Environment notes (cloud sessions)

- `luarocks.org` is blocked by the network policy. Use Ubuntu packages instead: `apt-get install -y lua5.1 liblua5.1-0-dev luarocks lua-busted lua-check lua-dkjson`. `luarocks --lua-version=5.1 install luacov` does work, because it installs from a GitHub mirror.
- A busted run takes about 17 s; the network simulations dominate, since FNV-1a costs more than Adler-32 did. The coverage run (`busted --run=coverage && luacov`) takes about 12 s and leaves out the property tests, which take minutes under the coverage hook.
- `git clone https://github.com/...` works through the proxy, but plain HTTPS to github.com pages returns 403, and `repos.wowace.com` (the WowAce SVN) is blocked.
- The only locales available are C and C.UTF-8. So no test here can show why Core compares strings byte-wise instead of with `<`.
- `addon/spec/helpers/client.lua` is the addon's fake client. It loads the real TOC and libraries, and provides WoW's `xpcall`, which passes arguments through; AceAddon depends on that. It collects errors the libraries catch, and raises them.
- `spikes/mock/wowmock.lua` is a rough fake client with a per-prefix token bucket (burst 10, 1/s) and loopback delivery. It's good for catching runtime errors. It doesn't show how the real client behaves.
