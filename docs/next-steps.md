# Status and next steps

The handoff between sessions. Read this after `CLAUDE.md`. Before you finish, update it: move what you finished into "Where things stand" and rewrite "Next steps".

Last updated: 2026-09-26 (fifth session that day: open questions closed out, merged to main).

## Where things stand

On 2026-09-26 Will asked for the remaining work to be built on best assumptions, with a big validation pass later. So this session broke the phase gate on purpose: Phases 2–6 were built before Phase 0 and Phase 1 were checked in game. **Nothing in design.md §12 is ticked.** Every criterion still needs its evidence from the Forever client or the live host. What passes outside the game is noted under each phase in §12.

### What exists

| Part | Where | State |
|---|---|---|
| Spike tooling 01–02 | `spikes/CorkSpike/` | Dropped by Will; kept until removed (next step 3). |
| Spike tooling 03–06 | `spikes/CorkSpike2/`, `spikes/install_probe.py` | Dropped by Will; kept until removed (next step 3). |
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

### First in-game run (fourth session)

Will installed the addon and CorkSpike in the 1.60.1 beta (build 70009) and ran part of spike 01/02 before deciding **not to do the spike testing**: from here we patch and test the main addon directly. Nothing from the spikes is a prerequisite any more.

- **Fixed: every send failed.** The client's Lua raises "Division by zero" (stock Lua returns inf), and LibSerialize v1.2.2 checks for negative zero with `1 / num`, so any envelope holding a `0` threw. Patched in `Libs/LibSerialize` (listed in `Libs/README.md`); `wire_spec` fails if a re-vendor brings it back. New §2 row in design.md.
- **Fixed: "Error loading Corkboard_Cloud/Data.lua".** The folder was copied from the repo, where `Data.lua` is gitignored. `python tools/package_addon.py --install "<beta>/Interface/AddOns"` now builds the zip and unzips it there (keeping a companion-written `Data.lua`); use it for every re-install.
- **Gate:** spike 01 showed `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()` is **true while idle** with sends succeeding, and `InChatMessagingLockdown()` false. `Gate.CHECKS` is now `InChatMessagingLockdown` only.
- **Own echoes:** CorkSpike failed to recognise its own whispers by exact `Name-Realm` (every arrival counted as "peer1"; the realm is "Classic Beta PvP 2"). Corkboard's echo check in `Net.lua` now ignores case and the realm's spaces, hyphens and apostrophes, and logs `? X shares our name (we are Y)` once to the debug panel if a same-named sender still gets through. If that line shows up, it's the echo: fix `nameKey` from what it prints.
- **Fixed: Forever names have surnames.** `UnitFullName("player")` returns `"Aprune", "Proudshield"` (the surname where the realm goes), so the addon called itself `Aprune-Proudshield` while CHAT_MSG_ADDON names it `Aprune Proudshield-ClassicBetaPvP2`. Its own echo showed as "Synced with Aprune Proudshield-…" and a phantom member. `identity()` now uses `GetPlayerInfoByGUID` (whole name, empty realm for our own) plus `GetNormalizedRealmName()`; the fake client mimics Forever's names and `net_spec` covers it. Boards made before the fix have the old name as owner and author: recreate them.
- **Cloud sync works locally:** API on `127.0.0.1:8000`, companion `setup` then `watch`; first sync pushed 4 and pulled 3, and the addon showed "Cloud 1m ago". Next is deploying the API so a second player can reach it.
- `addon_spec` now reads TOCs with CRLF normalised, so `busted` passes on a Windows checkout. Lua tests run in WSL Ubuntu here (`apt install lua5.1 lua-busted lua-check lua-dkjson`).

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

- Window, templates and popups: `UI/Main.lua`, `UI/Popups.lua`, `UI/Members.lua`, `UI/Debug.lua`.
- Hidden password channels (join, hiding from chat frames, the wrong-password notice, sender names): `Net.lua`.
- Link insertion and link round trips: `UI/Links.lua`, `Core/Sanitise.lua`.
- The live client's folder name at launch: `companion/corkboard_companion/discover.py` lets the player pick if it guesses wrong.
- The Social pane's Channels list may still show a board's channel; "never shows" covers chat frames only.

### Still to do before release

- **Deploy:** `api-image.yml` builds the API image on pull requests and `api-v*` tags. `infra/compose.yaml` needs `OWNER` and `TAG`, and the Caddyfile the real domain. The backup service installs sqlite with `apk` at start, so it needs network access.
- **Companion:** the tkinter window and the PyInstaller build need a run on Windows and macOS; there's no code-signing certificate yet.
- **Stores:** CurseForge and Wago need project IDs in the TOCs, tokens as secrets, and a Forever listing. Until then releases are GitHub-only.
- **Libraries:** LibDBIcon-1.0 for the minimap button, and a licence check on LibDataBroker-1.1 before publishing.

## Next steps

Do these in order unless Will says otherwise.

1. **Will: the Phase 1 check.** Install with `python tools/package_addon.py --install "C:/wow/World of Warcraft/_classic_beta_/Interface/AddOns"`. Then:
   1. `/console scriptErrors 1`, then `/cork`. Click **New**, name the board `Molten Core prep`.
   2. **New Note**: type `Need 4x `, shift-click an item in your bags, pick the blue tag, Save. Add `Bring fire resistance` and a note long enough to wrap.
   3. Hover the item link (tooltip), click it (item pops up), hover a card (Edit and Delete replace the age).
   4. Edit the second note, delete the third, search `fire`, then clear the search. Try saving `|T`: Save stays greyed with a yellow message.
   5. Make a second board, rename it, select the first again. `/reload`, `/cork`: everything is still there.
   6. Escape closes the editor, then the window; the window drags; the addon compartment lists Corkboard.
2. **Will: the Phase 2–4 check.** Needs two clients: two accounts, or a friend.
   1. On A: open the **Members** tab, click the invite box, Ctrl+C, and send it to B out of game. On B: **Join**, paste. Within about 15 s B shows the board's name and A's notes, and once the catch-up finishes the status line reads "Synced with A …".
   2. On both: nothing in any chat tab mentions a `Cork…` channel, even after `/reload`.
   3. A edits a note: B shows it within 5 s. `/cork debug` on both: the gate is Open, and the log shows the PUT.
   4. A dies (or pulls a dungeon boss) and edits while dead: A's status line says "Paused · N messages queued". After the res, B has the edits within 10 s, with no Lua errors.
   5. B logs out. A makes 20 notes, edits 5 and deletes 3. B logs in: within 60 s both debug panels show the same digest, and B's log shows IDX for only some buckets.
   6. A removes B in the Members tab: B stops getting A's edits. A sends the new invite, B joins with it, and syncing resumes.
   7. Send Lua errors and screenshots of the window, the Members tab, the debug panel and the status line.
3. **Apply the results.** Fix whatever the checks turn up and tick the §12 items that have their evidence. Since the spikes are dropped, `spikes/`, its CI smoke steps and `Corkboard.Sanitise` (kept only for CorkSpike2) can go in their own small change. If the 1.60 client has `C_EncodingUtil`, it could replace LibSerialize and LibDeflate.
4. **Deploy the API** following `infra/README.md`, then the Phase 5 checks: health over TLS from outside the tailnet, the dashboard unreachable, and a restore drill. Then install the companion (`pip install ./shared/python ./companion`, `corkboard-companion setup --api https://corkboard.<domain>`) and run the "B edits and logs out, A's companion syncs, A reloads" check for real.
5. **LibDBIcon and the minimap button** once Will supplies a current LibDBIcon build: add it to the TOC after LibDataBroker and to `addon_spec`, and register `Corkboard.launcher` with its position in `CorkboardDB.global`.
6. **Phase 6 for real:** CurseForge and Wago IDs and tokens, a signing certificate, and a Windows/macOS test of the companion's window and PyInstaller build.

## Open issues

- **Note-id collision** is fixed for the common case (§4.2). Two installs of one character that both create notes before either has seen the other's can still produce the same id, and LWW keeps one. Accepted for v1.
- **Board deletion is local-only.** Closing a board for everyone is out of scope for v1 (§14.5).
- **Digest blind spot:** the digest can't see a same-`(rev, editor)` tie with different content (§4.3). Those ties resolve through live `PUT`s or the cloud. Accepted for v1.
- **Tombstones are never collected**, and the API caps a board at 1,000 rows including them. Accepted for v1 (§14.7).
- **LibDataBroker-1.1 licence.** Its repository states none. Check before publishing.

## Environment notes (cloud sessions)

- `luarocks.org` is blocked by the network policy. Use Ubuntu packages instead: `apt-get install -y lua5.1 liblua5.1-0-dev luarocks lua-busted lua-check lua-dkjson`. `luarocks --lua-version=5.1 install luacov` does work, because it installs from a GitHub mirror.
- PyPI works: `pip install -e shared/python -e "api[test]" -e "companion[test]"`. There's no tkinter and no Docker daemon, so the companion's window and the API image can't be tried here.
- `busted` takes about 24 s. The coverage run (`busted --run=coverage && luacov`) takes about 80 s; it skips `property_spec`, `sync_property_spec` and anything tagged `#slow`.
- `git clone https://github.com/...` works through the proxy, but plain HTTPS to github.com pages returns 403, and `repos.wowace.com` (the WowAce SVN) is blocked.
- The only locales available are C and C.UTF-8.
- `addon/spec/helpers/client.lua` is the fake client. It loads the real TOC and libraries, and now runs several clients on one `Client.Network`: password channels, chat frames with message filters, the server throttle, lockdown (`client.locked`), secret values (`client.secrets`), ChatThrottleLib's OnUpdate, and C_Timer. `Client.new({ cloud = … })` also runs a `Corkboard_Cloud/Data.lua`.
- `addon/spec/helpers/sim.lua` is a faster, pure-Lua simulator of several members (store, outbox and sync engine, the real wire format, latency, loss and the throttle), for protocol tests.
- `spikes/mock/wowmock.lua` is a rough fake client for the spike addons only.
