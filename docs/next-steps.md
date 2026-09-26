# Status and next steps

The handoff between sessions. Read this after `CLAUDE.md`. Before you finish, update it: move what you finished into "Where things stand" and rewrite "Next steps".

Last updated: 2026-09-26 (third session that day: the over-engineering audit).

## Where things stand

On 2026-09-26 Will asked for the remaining work to be built on best assumptions, with a big validation pass later. So this session broke the phase gate on purpose: Phases 2–6 were built before Phase 0 and Phase 1 were checked in game. **Nothing in design.md §12 is ticked.** Every criterion still needs its evidence from the Forever client or the live host. What passes outside the game is noted under each phase in §12, and every guess the code rests on is listed under "Assumptions to check" below.

### What exists

| Part | Where | State |
|---|---|---|
| Spike tooling 01–02 | `spikes/CorkSpike/` | Ready; never run in game. |
| Spike tooling 03–06 | `spikes/CorkSpike2/`, `spikes/install_probe.py` | Ready; smoke-tested against `spikes/mock/`. Templates in `docs/spikes/03-06`. |
| Phase 1: local boards | `addon/Corkboard/` | Built last session; not run in game. |
| Phase 2: invites, channels, live PUTs | `Core/Invite.lua`, `Core/Wire.lua`, `Net.lua`, `UI/Members.lua` | Built; passes between fake clients running the real addon. |
| Phase 3: anti-entropy, debug panel | `Core/Sync.lua`, `UI/Debug.lua` | Built; passes in the simulator (`addon/spec/helpers/sim.lua`). |
| Phase 4: gate, outbox, bulk rule, fuzz corpus | `Core/Gate.lua`, `Core/Outbox.lua`, `shared/test-vectors/sanitise_fuzz.json` | Built; passes in simulation and between fake clients. |
| Phase 5: Python core | `shared/python/corkcore` | Passes every shared vector plus Hypothesis properties. |
| Phase 5: sync API | `api/` | Passes pytest; the real server answered curl here. Image not built here (no Docker daemon); CI builds it. |
| Phase 5: companion | `companion/`, `addon/Corkboard_Cloud/` | Passes pytest, including the real addon loading the `Data.lua` it writes. |
| Phase 5: hosting | `infra/` | Compose, Caddyfile and `infra/README.md`; not deployed. |
| Phase 6: packaging | `tools/package_addon.py`, `.pkgmeta`, `.github/workflows/release.yml`, `companion/corkboard-companion.spec`, `companion/corkboard_companion/gui.py` | Zip builder tested; the GUI, PyInstaller build and store uploads are untested. |
| CI | `.github/workflows/ci.yml`, `api-image.yml` | Green on the branch: luacheck, busted, coverage gate (≥ 95%), spike smoke tests, pytest for corkcore, API, companion and packaging, and a check that the fuzz corpus is current. |

Tests: `busted` runs 556 (Core coverage 98.7%, merge core 100%; the coverage run skips `#slow` specs); pytest runs 140 (corkcore), 18 (API), 32 (companion) and 1 (packaging).

### Spec changes this session

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

## Assumptions to check

Grouped by what settles them. Each names where it lives in code, so a wrong guess is a small change.

### Settled by the spikes (Phase 0)

| # | Assumption | Where | Spike |
|---|---|---|---|
| S1 | The restriction check is `C_ChatInfo.InChatMessagingLockdown()`, else `AreOutgoingAddonChatMessagesRestricted()` (in `C_ChatInfo` or global). A check that errors counts as open. | `Core/Gate.lua` `Gate.CHECKS` | 01 |
| S2 | `Enum.SendAddonMessageResult` exists; a result whose name has "Lockdown" or "Restrict" means restricted, "Throttle" means throttled. | `Gate:classify` | 01 |
| S3 | The throttle is about 1 message/s with a burst near 10, per prefix, counting messages not bytes. The outbox assumes 8 and 0.9/s; the simulator and fake client use 10 and 1/s. | `Outbox.BURST/RATE`, `helpers/sim.lua`, `helpers/client.lua` | 02 |
| S4 | `JoinTemporaryChannel(name, secret)` takes the 24-character secret as the password, and a 12-character `Cork…` name. | `Net:Refresh`, `Store.channelName` | 03 |
| S5 | Three board channels per character fit alongside the player's own channels. | `Net.MAX_CHANNELS` | 03 |
| S6 | Password channels reach connected realms (and maybe beyond). | §5.1 | 03 |
| S7 | `ChatFrame_RemoveChannel` (or `ChatFrameUtil.RemoveChannel`) plus message filters on the channel notice, text, join and leave events keep the channel out of every chat frame. Waiting 8 s after login keeps General and Trade on their usual numbers. | `Net.lua` `hide`, `filter`, `JOIN_DELAY` | 03, Phase 2 check |
| S8 | A wrong password arrives as `CHAT_MSG_CHANNEL_NOTICE_USER` with notice `WRONG_PASSWORD` and the channel's base name in arg 9. | `Net:OnChannelNotice` | 03 |
| S9 | `CHAT_MSG_ADDON` on a channel carries the channel name in arg 8 (or 5) and its number in arg 7; a same-realm sender may lack `-Realm`. The code tries all three. | `Net:OnAddonMessage` | 03 |
| S10 | Item links may use `|cnIQ4:` named colours, and every link a player makes passes the sanitiser and survives the round trip. | `Core/Sanitise.lua`, §6 | 04 |
| S11 | The shift-click inserter is `ChatFrameUtil.InsertLink` or `ChatEdit_InsertLink`. | `UI/Links.lua` | 04 |
| S12 | BNet: not built. If spike 05 shows a better throttle, it becomes the bulk P2P route. | §5.1 | 05 |
| S13 | Forever's flavour string and product folder: the companion guesses `wow_forever`, `wow_classic_forever`, `wow_classic_beta`, `wow_classic_ptr` and the matching folders, and lets the player pick. | `companion/.../discover.py` | 06 |
| S14 | `GetServerTime()` is close to Unix time: the companion's `syncedAt` and the addon's 7-day "cloud-enabled" window compare them. | `Sync:cloudActive` | 06 |

### Settled by playing it (Phases 1–4 in game)

| # | Assumption | Where |
|---|---|---|
| G1 | The Phase 1 UI calls from last session (ScrollBox, `PortraitFrameTemplate`, the StaticPopup edit box, text measurement). | `UI/Main.lua`, `UI/Popups.lua` |
| G2 | The new templates and helpers exist: `PanelTabButtonTemplate` (else `CharacterFrameTabButtonTemplate`), `PanelTemplates_*`, `UICheckButtonTemplate`, `InputBoxTemplate`, `C_ClassColor` or `RAID_CLASS_COLORS`, `C_Timer.NewTimer`, `date()`, `ReloadUI()`. | `UI/Main.lua`, `UI/Members.lua`, `UI/Debug.lua` |
| G3 | ChatThrottleLib (from Ace3 r1403) works on 16001, and its callback passes `(arg, didSend, result)`. | `Net:Send` |
| G4 | The class token from `UnitClass("player")` isn't a secret value. | `Corkboard.lua` |
| G5 | Redrawing the window at most every 0.2 s during a catch-up is cheap enough. | `Corkboard:ChangedSoon` |
| G6 | The Channels list in the Social pane will still show the board's channel; only chat frames are covered by "never shows". Decide whether that's acceptable. | §12 Phase 2 |

### Design choices for Will to confirm

| # | Choice | Where |
|---|---|---|
| D1 | Rotation moves the board to a new channel. A member who missed it sits alone in the old channel ("Nobody online") until they get the new invite; the "invite out of date" popup only fires if someone else holds that channel name. See §14 Q6. | §5.1 |
| D2 | No whispers at all; every reply is broadcast on the board transport. | §5.1 |
| D3 | Guild boards use GUILD *instead of* a channel (the v0.2 comment said "also"). §14 Q4 is still open. | `Net.wanted`, `route` in `Net.lua` |
| D4 | The three channel slots go to the current board, then the most recently selected. Other boards sync only through the cloud and show "Not connected". | `Net.wanted` |
| D5 | Presence: a member counts as online for 13 minutes after any message; a periodic HELLO is skipped at most once in a row, so everyone speaks at least every ~12 minutes. | `Sync.PRESENCE`, `scheduleHello` |
| D6 | Permissions: any member edits or deletes any note; only the owner removes members or rotates, enforced in the UI and `/cork` only (§14 Q3). The API lets any holder of the old secret rotate. | `Store:removeMember`, `api/.../app.py` |
| D7 | Removing a member marks them removed and rotates; their later messages are ignored. Rejoining with a fresh invite un-removes them. | `Sync:receive`, `Store:joinBoard` |
| D8 | "Cloud-enabled" for the bulk rule means the companion synced this board in the last 7 days, not just `board.cloud`. | `Sync.CLOUD_FRESH` |
| D9 | The 150 bytes/note estimate for the 8 KB bulk rule, and the partial catch-up of the responder's newest 20. | `Sync.NOTE_BYTES`, `Sync.PARTIAL` |
| D10 | One shared Python package (`shared/python/corkcore`) instead of copies in `api/` and `companion/`. `CLAUDE.md` now says so. | `shared/python` |
| D11 | The Members tab holds the cloud and guild options; there's no Settings tab yet. | `docs/ui-style.md` Phase 2 notes |
| D12 | The API counts rate limits per board before checking the secret, so failed guesses count too. | `api/.../app.py` |

### Infrastructure and packaging

| # | Item |
|---|---|
| I1 | The API image has never been built: no Docker daemon here. `api-image.yml` builds and smoke-tests it on pull requests and `api-v*` tags. |
| I2 | `infra/compose.yaml` needs `OWNER` and `TAG`, and the Caddyfile needs the real domain. The backup service installs sqlite with `apk` at start, so it needs network access. |
| I3 | The companion's window (tkinter) and the PyInstaller spec have never run: this container has no tkinter or Windows. |
| I4 | No code-signing certificate; the release workflow's signing step is a placeholder. |
| I5 | CurseForge and Wago need project IDs in the TOCs and tokens as secrets, and must list Forever. Until then releases are GitHub-only. |
| I6 | LibDBIcon-1.0 is still missing (WowAce SVN is blocked here), so there's no minimap button yet. |
| I7 | LibDataBroker-1.1's licence is still unchecked. |

## Next steps

Do these in order unless Will says otherwise.

1. **Will: install and run the spikes** (settles S1–S14). Copy `spikes/CorkSpike`, `spikes/CorkSpike2` and `addon/Corkboard` into `_classic_beta_/Interface/AddOns` (copy, don't symlink). Run `/cspike all` and the canary (see `spikes/CorkSpike/README.md`), then the CorkSpike2 runs in `docs/spikes/03-06`, and `python3 spikes/install_probe.py` on the desktop. Paste each report into its `docs/spikes/NN-*.md`.
2. **Will: the Phase 1 check** (settles G1). Build the zip with `python3 tools/package_addon.py`, or copy `addon/Corkboard` and `addon/Corkboard_Cloud` (add an empty `Data.lua` to the latter: `CorkboardCloudData = nil`). Then:
   1. `/console scriptErrors 1`, then `/cork`. Click **New**, name the board `Molten Core prep`.
   2. **New Note**: type `Need 4x `, shift-click an item in your bags, pick the blue tag, Save. Add `Bring fire resistance` and a note long enough to wrap.
   3. Hover the item link (tooltip), click it (item pops up), hover a card (Edit and Delete replace the age).
   4. Edit the second note, delete the third, search `fire`, then clear the search. Try saving `|T`: Save stays greyed with a yellow message.
   5. Make a second board, rename it, select the first again. `/reload`, `/cork`: everything is still there.
   6. Escape closes the editor, then the window; the window drags; the addon compartment lists Corkboard.
3. **Will: the Phase 2–4 check** (settles G2–G6, D1–D5). Needs two clients: two accounts, or a friend.
   1. On A: open the **Members** tab, click the invite box, Ctrl+C, and send it to B out of game. On B: **Join**, paste. Within about 15 s B shows the board's name and A's notes, and once the catch-up finishes the status line reads "Synced with A …".
   2. On both: nothing in any chat tab mentions a `Cork…` channel, even after `/reload`.
   3. A edits a note: B shows it within 5 s. `/cork debug` on both: the gate is Open, and the log shows the PUT.
   4. A dies (or pulls a dungeon boss) and edits while dead: A's status line says "Paused · N messages queued". After the res, B has the edits within 10 s, with no Lua errors.
   5. B logs out. A makes 20 notes, edits 5 and deletes 3. B logs in: within 60 s both debug panels show the same digest, and B's log shows IDX for only some buckets.
   6. A removes B in the Members tab: B stops getting A's edits. A sends the new invite, B joins with it, and syncing resumes.
   7. Send Lua errors and screenshots of the window, the Members tab, the debug panel and the status line.
4. **Apply the results.** Update the code named in the assumption tables, then `docs/design.md`, and tick §12 items that have their evidence. Re-run `lua5.1 spikes/mock/smoke.lua …` if a spike needed fixing. Then make the cuts the audit left for this point: keep only the restriction check spike 01 finds (`Gate.CHECKS`), and only the chat-frame and link-insert functions spike 03 and 04 find (`hide` and `addFilter` in `Net.lua`, `Links.HookInsert`); drop `Corkboard.Sanitise` once spike 04 is recorded; and once every Phase 0 report is in, delete `spikes/` and the CI smoke steps. If the 1.60 client has `C_EncodingUtil`, a spike could decide whether it replaces LibSerialize and LibDeflate.
5. **Deploy the API** following `infra/README.md`, then the Phase 5 checks: health over TLS from outside the tailnet, the dashboard unreachable, and a restore drill. Then install the companion (`pip install ./shared/python ./companion`, `corkboard-companion setup --api https://corkboard.<domain>`) and run the "B edits and logs out, A's companion syncs, A reloads" check for real.
6. **LibDBIcon and the minimap button** once Will supplies a current LibDBIcon build (I6): add it to the TOC after LibDataBroker and to `addon_spec`, and register `Corkboard.launcher` with its position in `CorkboardDB.global`.
7. **Answer the open questions** in design.md §14 (1–7), and D1–D12 above.
8. **Phase 6 for real:** CurseForge and Wago IDs and tokens, a signing certificate, and a Windows/macOS test of the companion's window and PyInstaller build.

## Open issues

- **Note-id collision** is fixed for the common case (§4.2). Two installs of one character that both create notes before either has seen the other's can still produce the same id, and LWW keeps one. Accepted for v1.
- **Board deletion is local-only.** Closing a board for everyone is §14 question 5.
- **Digest blind spot:** the digest can't see a same-`(rev, editor)` tie with different content (§4.3). Those ties resolve through live `PUT`s or the cloud. Accepted for v1.
- **Tombstones are never collected**, and the API caps a board at 1,000 rows including them (§14 Q7).
- **LibDataBroker-1.1 licence.** Its repository states none. Check before publishing.
- **Hosting questions.** §14 questions 1–4 are still open (reverse proxy, tunnel, delete permissions, guild boards).

## Environment notes (cloud sessions)

- `luarocks.org` is blocked by the network policy. Use Ubuntu packages instead: `apt-get install -y lua5.1 liblua5.1-0-dev luarocks lua-busted lua-check lua-dkjson`. `luarocks --lua-version=5.1 install luacov` does work, because it installs from a GitHub mirror.
- PyPI works: `pip install -e shared/python -e "api[test]" -e "companion[test]"`. There's no tkinter and no Docker daemon, so the companion's window and the API image can't be tried here.
- `busted` takes about 24 s. The coverage run (`busted --run=coverage && luacov`) takes about 80 s; it skips `property_spec`, `sync_property_spec` and anything tagged `#slow`.
- `git clone https://github.com/...` works through the proxy, but plain HTTPS to github.com pages returns 403, and `repos.wowace.com` (the WowAce SVN) is blocked.
- The only locales available are C and C.UTF-8.
- `addon/spec/helpers/client.lua` is the fake client. It loads the real TOC and libraries, and now runs several clients on one `Client.Network`: password channels, chat frames with message filters, the server throttle, lockdown (`client.locked`), secret values (`client.secrets`), ChatThrottleLib's OnUpdate, and C_Timer. `Client.new({ cloud = … })` also runs a `Corkboard_Cloud/Data.lua`.
- `addon/spec/helpers/sim.lua` is a faster, pure-Lua simulator of several members (store, outbox and sync engine, the real wire format, latency, loss and the throttle), for protocol tests.
- `spikes/mock/wowmock.lua` is a rough fake client for the spike addons only.
