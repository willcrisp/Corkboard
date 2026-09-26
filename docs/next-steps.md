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
| 04 link round trip through LibDeflate | None (needs LibDeflate) | No |
| 05 `BNSendGameData` | Partly: `/cspike bnet` adds BNet to the shared-budget runs | No |
| 06 SavedVariables bug, install folder | None | No |

`docs/spikes/01-send-restriction.md` and `02-throttle.md` are templates, waiting for the pasted report. CorkSpike has only run against the mock client in `spikes/mock/`, never in game.

### Phase 1: local boards

- **Done:** the merge core in `addon/Corkboard/Core/` (`Util`, `Sanitise`, `Merge`, `Digest`). It's pure Lua 5.1 with no WoW API.
  - `busted` runs 263 tests, including seeded property tests. Line coverage of Core is 100% from the unit and vector tests alone.
  - `luacheck .` is clean.
  - The shared vectors are in `shared/test-vectors/`, and their README tells the Python ports how to run them.
- **Spec changes made along the way**, each explained in commit `50b4d4b`:
  - §4.3: a tie-break when `(rev, editor)` are equal, byte-wise comparison of names, and revs capped at 2^53 − 1;
  - §4.4: exact digest encoding;
  - §6: the sanitiser rejects instead of stripping, the full escape whitelist, and record field checks;
  - §7.3: the API upserts using the full §4.3 rule.
- **Not started:** the rest of Phase 1. That's the TOC, libraries, the AceDB store, board and note operations, the UI, link insertion and tooltips, and persistence across `/reload`.

Phase 1 checklist in design.md §12: the "coverage ≥ 95% and all vectors pass in Lua" item is met. The others are open, so nothing is ticked yet.

## Next steps

Do these in order unless Will says otherwise. Keep one step per branch or PR.

1. **Process the spike 01/02 results** once Will has pasted them into `docs/spikes/`.
   - Fill in "Design impact".
   - Update `docs/design.md`: the real restriction-check name and restricted result code (§5.5), and the measured throttle (§2, §5.6, and the §11 simulator's burst).
   - If the report shows CorkSpike misbehaving on the real client, fix it. Re-check with `lua5.1 spikes/mock/smoke.lua spikes/CorkSpike/CorkSpike.lua`.
2. **Phase 1: addon skeleton and store.**
   - Add `addon/Corkboard/Corkboard.toc` (`## Interface: 16001`). It loads the libraries, then `Core/Util.lua`, `Sanitise.lua`, `Merge.lua` and `Digest.lua` in that order, then the rest.
   - Vendor the §13 libraries under `addon/Corkboard/Libs/`, using current builds that load on modern-API clients.
   - Build an AceDB store for `CorkboardDB` (§4.1) that makes every change through `Merge`. It covers board create, rename and delete, and note create, edit and delete.
   - Add `/cork` commands that are enough to exercise it.
   - Keep the pure logic (id generation, board operations) in Core so busted can test it. Keep WoW calls in thin wrappers.
3. **Phase 1: UI.**
   - Build the board view, note editor, link insertion and tooltips, per `docs/ui-style.md` and `docs/mockups/`.
   - Links: shift-click inserts through a `hooksecurefunc` post-hook. `OnHyperlinkEnter` shows the tooltip and `OnHyperlinkClick` calls `SetItemRef`.
   - The editor must refuse text that `Sanitise.text` rejects. Otherwise peers will drop the note.
4. **Spike tooling for 03–06.** This can run alongside steps 2 and 3.
   - Spike 04 needs LibDeflate, so it fits naturally after step 2 vendors it.
   - Spike 05 can extend `/cspike bnet` with payload-size cases.
5. **CI:** a GitHub Actions workflow that runs `luacheck .`, `busted`, and the coverage run.
6. **Later, in Phase 5:** Python ports of the merge core in `api/` and `companion/`. They must pass every file in `shared/test-vectors/`, plus Hypothesis property tests (§11).

## Open issues

- **Note-id collision.** Ids are `<8-hex hash of author GUID>-<per-author counter>` (§4.2). If the counter lives in each install's SavedVariables, one character playing on two computers can create two different notes with the same id. Last-writer-wins then silently discards one of them. The fix for step 2: derive the next counter from the board itself (the highest counter for my prefix on the board, plus 1). Only two offline installs creating notes at the same time can still collide. Record the rule in §4.2.
- **Named colours.** The sanitiser allows `|cnNAME:` colours such as `|cnIQ4:`, in case Forever's item links use them. Spike 04 confirms. Add a vector for whatever link format it finds.
- **Digest blind spot.** The digest can't see a same-`(rev, editor)` tie with different content (§4.3). Those ties resolve through live `PUT`s or the cloud. That's acceptable for v1, but keep it in mind for the Phase 3 tests.
- **Hosting questions.** §14 is still open (reverse proxy, tunnel, delete permissions, guild boards).

## Environment notes (cloud sessions)

- `luarocks.org` is blocked by the network policy. Use Ubuntu packages instead: `apt-get install -y lua5.1 liblua5.1-0-dev luarocks lua-busted lua-check lua-dkjson`. `luarocks --lua-version=5.1 install luacov` does work, because it installs from a GitHub mirror.
- A busted run takes about 6 s. The coverage run (`busted --run=coverage && luacov`) leaves out the property tests, which take minutes under the coverage hook.
- The only locales available are C and C.UTF-8. So no test here can show why Core compares strings byte-wise instead of with `<`.
- `spikes/mock/wowmock.lua` is a rough fake client with a per-prefix token bucket (burst 10, 1/s) and loopback delivery. It's good for catching runtime errors. It doesn't show how the real client behaves.
