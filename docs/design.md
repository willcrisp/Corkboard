# Corkboard: Shared Post-it Boards for WoW: Forever

**Status:** Draft v0.2 · **Target client:** World of Warcraft: Forever 1.60.x (TOC `## Interface: 16001`, game type `camelot`) · **Addon prefix:** `CORK`
**Backend hosting:** Docker stack on Will's Arcane host, exposed on a public DNS name.

Corkboard is an addon for World of Warcraft: Forever. A player creates a board and shares it with an invite string. Everyone on the board can add free-text notes containing item, quest, spell and similar links. Boards sync between members peer-to-peer in game. A companion app and a self-hosted sync API let members catch up even when no other member is online, and a web app (a PWA for desktop and phone) reads and writes the same boards away from the game.

> **v0.2 changes from v0.1 (retail):**
> - Retargeted to Forever 1.60.
> - Designed around the per-prefix addon-message throttle, so bulk catch-up now prefers the cloud path.
> - Bucketed anti-entropy from day one.
> - Lockdown gate uses the client's own restriction check.
> - The companion discovers the Forever install by product.
> - The backend has a concrete Arcane + public DNS deployment.

---

## 1. Goals and non-goals

**Goals**
- Create multiple boards and share them with an invite string.
- Any member can add, edit and delete notes, including clickable item, quest, spell and achievement links with tooltips.
- Members converge on the same board state regardless of who is online when.
- Live updates when members are online together.
- Offline catch-up from any online member (P2P, small deltas) or from the cloud (companion; any size, nobody else online).
- Read and write boards away from the game, on a desktop browser or a phone (the web app, §7.4).
- No data loss under concurrent edits. Deleted notes never come back.

**Non-goals (v1)**
- Real-time co-editing inside one note. The whole note is the unit of change.
- Verifiable authorship (see §10).
- Rich formatting beyond colour codes and links.
- Retail, Classic Era, or other Classic flavours. The core is portable, but only Forever is tested.

---

## 2. Target client facts (Forever 1.60)

Forever has vanilla-era content but a **modern (Mainline-style) addon API**, and it ships with **Midnight-style addon restrictions**. So:

| Fact | Design consequence |
|---|---|
| The TOC interface is `16001` (check with `/dump (select(4, GetBuildInfo()))`). The client uses the modern `C_*` namespaces. | Write against the modern API (`C_ChatInfo.*`, etc.), not the 1.12 or Classic Era API. |
| Combat and chat values can be **secret** in restricted contexts. `SendAddonMessage` refuses secret arguments. | Never send data derived from unit or combat APIs. Drop any received payload where `issecretvalue(msg)` is true. Corkboard sends user-typed text, plus the item links of the gear feed (§9.1), which come from the inventory API, the quest ids and levels of each member's quest log (§9.3), which come from the quest log API, and a player's name that the Players editor's **Target** button fills in (§9.4), which comes from the unit API. Each is checked with `issecretvalue` before use, and a secret one is left out. |
| **Addons can't read the combat log.** `CombatLogGetCurrentEventInfo` is nil, and registering `COMBAT_LOG_EVENT_UNFILTERED` is blocked as "only available to the Blizzard UI". `C_CombatLog` and `C_DamageMeter` exist. Seen in game on 2026-09-26. | No feature can use individual hits, so a "biggest crit" leaderboard was dropped. |
| `PLAYER_EQUIPMENT_CHANGED` fires with the slot, and `GetInventoryItemLink("player", slot)` returns a plain (not secret) link with a quality from `C_Item.GetItemQualityByID`. Unequipping gives a nil link. Seen in game on 2026-09-26. | The gear feed (§9.1) is built on these. |
| With a profession window open, `C_TradeSkillUI` works as on retail: `GetAllRecipeIDs()` returns the profession's whole catalogue (592 for Leatherworking), and `GetRecipeInfo(id).learned` marks the known ones (8 at skill 47/75). Recipe IDs are 7 digits (`1263079`), and the record's `hyperlink` is the crafted item's link. `GetBaseProfessionInfo()` gives `professionName`, `professionID` (165), `skillLevel` and `maxSkillLevel`. With no window open everything is empty or zero and `IsTradeSkillReady()` is false. `GetNumTradeSkills` and `GetNumCrafts` are nil, and the window is `ProfessionsFrame`. Seen in game on 2026-09-26. | Anything that shares recipes can read a profession only while its window is open, and must filter on `learned`. One code path covers every profession, Enchanting included. |
| `C_TradeSkillUI.GetTradeSkillListLink()` (window open) returns a `trade` link and the skill line: `\|cffffd000\|Htrade:Player-4613-00CD2154:2108:165\|h[Leatherworking]\|h\|r`, `2108`. Seen in game on 2026-09-26. `GetRecipeLink(id)` returns a plain (not secret) `enchant` link, `\|cffffd000\|Henchant:1263079\|h[Leatherworking: Sewing Machine]\|h\|r`. Not yet known: what another player sees on clicking the `trade` link, online or offline. | The sanitiser accepts both link types (§6), and the Professions tab (§9.2) builds `enchant` links from recipe ids. |
| **Assumed, not yet seen in game:** `C_Item.GetItemInfoInstant(link)` returns the item's class and subclass (6th and 7th returns, `classID` and `subclassID`) and equip slot (4th), and `C_Item.GetItemInfo(link)` (or `GetItemInfo`) returns the required level 5th, or nil until the client has loaded the item, starting the load. | The Professions tab's level and armour filters (§9.2) read the crafted item's details with these at scan time. |
| **Assumed, not yet seen in game:** the quest log reads through the Mainline `C_QuestLog.GetNumQuestLogEntries` / `C_QuestLog.GetInfo(i)` (with `questID`, `level`, `isHeader`, `isHidden`), falling back to the Classic `GetQuestLogTitle`. `C_QuestLog.GetTitleForQuestID` names a quest outside your own log once `C_QuestLog.RequestLoadQuestByID` has loaded it (`QUEST_DATA_LOAD_RESULT`), and a `quest:<id>:<level>` link built from those shows a tooltip. Forever's quest log holds 40 quests. | The quest logs (§9.3) are built on these. If the Classic path is the one in use, quests under a collapsed header may be missed. |
| **Assumed, not yet seen in game:** `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, fn)` runs after a unit tooltip is filled (Mainline 10.0.2+), with `GameTooltip:HookScript("OnTooltipSetUnit", …)` as the fallback. `GetPlayerInfoByGUID(UnitGUID(unit))` gives another player's whole name (surname included) and their realm, empty for your own; `UnitName` is the fallback. `GROUP_ROSTER_UPDATE` fires as a group changes, with `IsInGroup`, `IsInRaid`, `GetNumGroupMembers` and the `party1`–`4` / `raid1`–`40` unit tokens. Unit names may be secret in combat. | The player notes' tooltip line and group warning (§9.4) are built on these. Both skip a unit whose name or GUID is secret. |
| Outgoing addon messages are restricted during encounters, and briefly around death and resurrection too. | The lockdown gate polls the client's restriction check instead of tracking `ENCOUNTER_START`/`END` flags, which can get stuck (§5.5). |
| Addon messages have a **per-prefix throttle across all chat types**: roughly 1 message per second, with a small burst allowance. `SendAddonMessage` returns a result code. | About 255 bytes/sec sustained per prefix. P2P is for live edits and small deltas. Bulk sync goes through the cloud (§5.6). |
| The client's Lua raises "Division by zero" on `x / 0` (and `0/0`), where stock Lua 5.1 returns inf or nan. Seen in game on 2026-09-26. | Tests outside the game can't catch it. No code, vendored libraries included, may divide by a value that can be zero; `Libs/README.md` lists the patches this needed. |
| In the beta, the addon lives under `_classic_beta_`. The live install folder is not yet known (launch is 2026-11-04). | The companion finds the install by product, not by folder name (§7.1). |
| **Beta bug:** SavedVariables are written but not reloaded on a fresh client launch. Symlinked addon folders also never read their SavedVariables. | Phases 1–5 use `/reload` for persistence testing until this is fixed. The companion must never be tested against symlinked dev folders. |

---

## 3. Architecture

```
 ┌──────────── WoW: Forever client (each member) ───────────┐
 │  UI (board list, note cards, editor)                     │
 │  Store  (AceDB → SavedVariables CorkboardDB)             │
 │    └─ pure-Lua Merge + Digest core                       │
 │  Sync engine ─ Outbox ─ Lockdown gate ─ Throttle budget  │
 │  Transports: board channel │ GUILD │ WHISPER │ BNet       │
 └───────┬──────────────────────────────────────────────────┘
         │ addon messages: live PUTs + small-delta anti-entropy
         ▼
   other members' clients

 ── cloud path (bulk + nobody-online catch-up) ──────────────────────
 SavedVariables/Corkboard.lua ─► Companion ─HTTPS─► corkboard.<domain>
 AddOns/Corkboard_Cloud/Data.lua ◄─ Companion ◄──── Caddy ► API ► SQLite
                                                      │  (Docker stack on Arcane)
 Web app / PWA (browser, phone) ◄─────HTTPS──────────┘  Caddy also serves the app
```

The same **merge core** (§4.3) runs in the addon (Lua 5.1), in the companion and API (Python), and in the web app (JavaScript). Shared JSON test vectors keep all four behaviourally identical.

---

## 4. Data model

### 4.1 Board

```lua
CorkboardDB.global.boards[boardId] = {
  id       = "k3f9x2m7q1pz8c4w",   -- 16 chars, random base36
  meta     = BoardMeta,            -- the board's name, replicated LWW (below)
  secret   = "…24 chars…",         -- shared by members: channel password + cloud credential
  owner    = "Will-Realm",
  created  = 1790000000,           -- GetServerTime()
  members  = { ["Name-Realm"] = MemberRecord, … },
  notes    = { [noteId] = Note, … },
  clock    = 0,                    -- highest rev seen (HLC-lite, §4.3)
  sync     = { lastPeer, lastPeerAt, lastCloudAt, cloudCursor, lastUsed, expired },
  cloud    = true,                 -- companion sync on by default now the API exists
  guild    = false,                -- sync over GUILD instead of a channel (§5.1)
  gear     = true,                 -- post this account's new rare+ gear here (§9.1); local, false opts out
  recipes  = true,                 -- share this character's recipes here (§9.2); local, false opts out
  quests   = true,                 -- share this character's quest log here (§9.3); local, false opts out
  oldSecrets = { … },              -- up to 5 retired secrets, newest first (§7.3 rotate)
  seen     = { ["Name-Realm"] = { at, class, level } },  -- local roster bookkeeping, never replicated
}
```

- **Storage.** `CorkboardDB` is an AceDB database. Boards live in its account-wide `global` section, so every character on the account sees the same boards. The selected board is per character (`CorkboardDB.char["Name - Realm"].current`). AceDB also writes its own `profileKeys`. The companion reads boards from `CorkboardDB.global.boards`.
- **Every change goes through the merge core.** Creating a board names it with `Merge.setMeta` and adds the creator as owner with `Merge.setMember`. Renaming is `Merge.setMeta`. Note changes are `Merge.createNote`, `editNote` and `deleteNote`.
- **Local-only fields.** `sync`, `seen` and `oldSecrets` never replicate. `sync.lastUsed` orders boards for the channel cap (§5.1), and `sync.expired` marks a board whose channel refused our password.
- **Deleting a board is local.** It removes the board from this account and isn't replicated. Other members keep their copies, and without the secret this client never hears the board again unless someone re-invites it. Closing a board for everyone is out of scope for v1 (§14.5).

### 4.2 Note

```lua
Note = {
  id      = "a1b2c3d4-0007",   -- <prefix>-<counter>, see "Note ids" below
  author  = "Will-Realm",
  created = 1790000123,
  rev     = 1790000456,        -- §4.3
  editor  = "Bob-Realm",       -- who produced this rev (tie-breaker)
  text    = "Need 4x |cff…|Hitem:…|h[…]|h|r for …",
  color   = 1,
  deleted = false,             -- tombstone; text cleared when true
  kind    = nil,               -- nil for an ordinary note, "gear" for a gear-feed entry (§9.1),
                               -- "recipes" for a character's recipe list (§9.2),
                               -- "quests" for a character's quest log (§9.3),
                               -- "player" for an entry on the avoid / good-player list (§9.4)
}
```

**Note ids** are `<prefix>-<counter>`:

- **Prefix:** `%08x` of FNV1a32 (§4.4) over the author's `UnitGUID("player")`. It's computed once at login, never from a secret value, so it's plain data by the time a note carries it. It's the same on every install of a character.
- **Counter:** one more than the highest counter of any note on this board whose id has my prefix, tombstones included. Counters are compared as numbers and written with at least 4 digits (`0007`), up to 999,999,999, which keeps ids within the sanitiser's 18 bytes. Counter 0 (`a1b2c3d4-0`) is never handed out: it's the character's quest log (§9.3).
- **Why the board, not the install:** a counter kept in each install's SavedVariables would let one character playing on two computers create two different notes with the same id, and LWW would silently discard one. Taken from the board, the counter moves past everything this client has seen. So only two installs creating notes while neither has seen the other's can still collide, which is accepted for v1. It also keeps two characters whose prefixes collide off each other's ids once their notes have synced.

`MemberRecord = { name, role = "owner"|"member", rev, editor, removed }` uses the same last-write-wins (LWW) rules as notes.

`BoardMeta = { name = "Molten Core prep", rev, editor }` is the board's name. The invite string carries only the id, secret and owner (§9), so the name has to replicate like any other record, and a rename is an LWW edit on the same board clock. A board holds one BoardMeta, not a map.

### 4.3 Merge rules

- **Clock:** on a local change, `rev = max(GetServerTime(), board.clock + 1)`, then `board.clock = rev`. On receiving a record that passes the sanitiser, `board.clock = max(board.clock, rev)`. `rev` and `created` are integers from 0 to 2^53 − 1 (`rev` from 1), the largest a Lua number holds exactly.
- **Winner:** the record with the greater `(rev, editor)`, compared lexicographically. `rev` compares as a number. `editor` compares byte by byte, not with Lua's `<`, whose order depends on the C locale. That way Lua and Python always agree.
- **Exact ties:** honest clients only produce two different records with the same `(rev, editor)` when one character edits on two installs. The tie then breaks on content: a tombstone beats a live note, then the greater `kind` (a missing kind counts as the empty string), `text`, `color`, `author` and `created`, in that order. MemberRecords break ties on `removed`, then `role`. BoardMeta breaks ties on the greater `name`, byte-wise. The digest can't see such a tie, so it resolves wherever both records meet (live `PUT`s or the cloud), not through anti-entropy.
- **Delete** is an edit with `deleted = true, text = ""`. Tombstones are kept (not GC'd in v1). A stale copy can never bring a deleted note back. A later edit from someone who hadn't seen the delete still wins, like any later edit.
- **Board state** is the union of all notes by `id`, with the winner rule applied per id. Merging is commutative, associative and idempotent, so relaying order and duplicates don't matter.

### 4.4 Digests (bucketed)

- `bucket(id) = FNV1a32(id) % 32`
- `bucketHash[i] = FNV1a32(sorted "id=rev;editor\n" lines in bucket i)`
- `boardDigest = FNV1a32(concat(bucketHash[0..31]))`

The details, pinned by `shared/test-vectors/digest.json` and `fnv1a32.json`:

- FNV1a32 is 32-bit FNV-1a (offset basis 2166136261, prime 16777619). The merge core implements it in pure Lua 5.1 without bit operators.
- `rev` is written in plain decimal, never in exponent form.
- Lines sort byte-wise. Tombstones are included. An empty bucket hashes to 2166136261.
- `concat` joins each bucket hash as 4 big-endian bytes.
- **Why not Adler-32** (v0.2 used it, since LibDeflate provides it): Adler-32 is blind to small structured changes in short inputs. A note's line only changes in the rev digits between two edits by the same editor, and revs that differ by 81 (digit changes of +1, −2, +1, such as `…184` → `…265`) leave both Adler sums unchanged. So do 810, 891 and many others. Two peers holding those two versions would see equal digests and never repair the stale one over P2P. The convergence property test found this. FNV-1a multiplies after every byte, so it has no such structure: a property test checks that no change to up to three adjacent rev digits collides, and any other pair of lines collides only by chance, about 1 in 2^32. Neither hash resists a member who crafts collisions on purpose, which the trust model (§10) already accepts.

The 32 bucket hashes are 128 bytes raw, about one addon message after compression. Only the notes in mismatched buckets are ever exchanged as indexes.

---

## 5. In-game sync protocol

### 5.1 Transports

| Transport | Use | Notes |
|---|---|---|
| **Board channel** | Primary broadcast | Hidden custom channel `Cork` + `%08x` of FNV1a32(`boardId .. "\|" .. secret`), joined with `JoinTemporaryChannel(name, secret)`, removed from every chat frame, and with its notices and text filtered out by a chat message filter. Cap of 3 active channel-backed boards per character: the current board, then the most recently used. Reach across connected realms is checked in the Phase 2 two-client test. |
| **GUILD** | Guild boards (`board.guild = true`) | Used instead of a channel, so it doesn't take a slot. |
| **WHISPER** | Not used in v1 | Targeted replies (IDX, NEED) ride the board's own transport with a `to` field instead (§5.3). |
| **BNet** (`BNSendGameData` / `BN_CHAT_MSG_ADDON`) | Members who are BNet friends | Not in v1. Worth a look after launch if bulk P2P proves slow. |

**Why the channel name includes the secret** (changed from `Cork<first 10 of boardId>`): a rotation (§10) must move the board to a channel the removed member can't reach. With an id-only name, a removed member who stays in the channel keeps it alive under the old password, and every member rejoining with the new secret is refused. A secret-derived name gives each secret its own channel. The cost: a member who missed a rotation sits alone in the old channel and sees "Nobody online" until they get the new invite; the "wrong password" notice (and the out-of-date invite popup) only fires if someone else is using the name.

**Why replies don't whisper:** responder suppression (§5.4) needs every member to see the winner's `IDX`, and the per-prefix throttle is shared across chat types (§2), so a whisper saves no budget. Broadcasting replies also lets other stale members pick up the `PUT`s. It removes the "No player named…" risk entirely.

### 5.2 Envelope

`{ v = 1, t = <type>, b = boardId, … }` goes through LibSerialize → LibDeflate `CompressDeflate` → `EncodeForWoWAddonChannel`, is split into chunks of at most 255 bytes, and each chunk goes to ChatThrottleLib (prefix `CORK`).

- **Chunks:** each addon message starts with two bytes, its index and the chunk count (both 1–32), then up to 253 bytes of the encoded text. A receiver keeps one buffer per sender and transport, and drops the buffer on any gap, repeat or count mismatch, so a lost chunk costs the whole message rather than corrupting it (raw deflate has no checksum). An envelope that needs more than 32 chunks (about 8 KB) is never sent. `Core/Wire.lua` implements this.
- **Why not AceComm** (the v0.2 plan): the `issecretvalue` check (§2) has to run before any code compares or slices the payload, and AceComm handles `CHAT_MSG_ADDON` itself; its multipart framing also can't detect a missing middle chunk. Corkboard's own framing is 40 lines, and ChatThrottleLib still does the pacing.

ChatThrottleLib priorities: live `PUT` = `"ALERT"`, handshake = `"NORMAL"`, bulk = `"BULK"`.

The outbox (§5.5) classifies each chunk's `SendAddonMessage` result by the client's own `Enum.SendAddonMessageResult` names: a throttle result is left to ChatThrottleLib, which re-queues it; a "lockdown" or "restricted" result puts the whole message back at the front of the outbox and closes the gate; anything else is counted as a failure.

### 5.3 Messages

| Type | Payload | When |
|---|---|---|
| `HELLO` | `r` nonce, `d` digest, `n` count, `c` clock, `k` buckets[32], `kc` per-bucket note counts[32], `md` members digest, `m` BoardMeta, `me` the sender's own MemberRecord, `cls` class token, `lvl` the sender's level (1–255, for the roster's Level column; anything else is ignored), `cl` when the sender's companion last synced this board (or false) | Login, joining a board, when lockdown clears, on `PLAYER_LEVEL_UP`, and every 5 min ± 60 s. A periodic HELLO is skipped if a HELLO for this board was seen < 2 min ago, but never twice running, so every member announces itself at least every ~12 min. |
| `IDX` | `to`, `r`, `e` = `{ {id, rev, editor}, … }` for mismatched buckets only, `bk` the buckets it covers completely; or, for a partial catch-up (§5.6), `p = 1`, `bh` notes behind, and the sender's newest 20 entries | Reply to a HELLO with a differing digest, broadcast on the board's transport. Split across several IDX when a board is large (60 entries each). |
| `NEED` | `to`, `ids` (up to 100) | Requester: ids where the peer's copy is newer. |
| `PUT` | `{ Note, … }`, packed to about 600 bytes before compression | Live on local edit; in reply to `NEED`; pushing our newer notes after an `IDX` diff. Always broadcast. |
| `MEMBERS` | `{ MemberRecord, … }`, 100 per message | After a local member change; and in reply to a HELLO whose `md` differs from ours, after a random 0.5–3 s delay that's cancelled if another member's MEMBERS arrives first. A member whose list still holds something the arrival lacked sends its own. |
| `META` | `BoardMeta` | After a local rename; and in reply to a HELLO carrying an older name or none, with the same suppression. |

Members digest: FNV1a32 of the sorted `name=rev;editor\n` lines of every MemberRecord, removed ones included, like the note buckets. The digest doesn't cover BoardMeta, so it rides on every HELLO; it's under 100 bytes. The v0.2 `CLOUD` message is the `cl` field. Receivers check every field's type and size; an envelope that fails is dropped and counted.

### 5.4 Catch-up flow

1. A logs in and broadcasts `HELLO(digest, buckets)`.
2. Each online member with a different digest schedules a reply. The first one to reply wins. Anyone who sees another member's `IDX` aimed at A cancels their own (**responder suppression**). The delay is **ranked**, not uniformly random: every member sorts the members it has heard from in the last 13 min, A excluded, by FNV1a32 of A's HELLO nonce and the member's name, and waits `0.3 s + rank × 1.0 s + random(0–0.4 s)` (rank capped at 4). Members agree on the order without talking, so the first in line normally answers and everyone else has seen its IDX before their own turn.

   **Why ranked** (changed from a uniform 0.5–3 s): with 4 possible responders, a uniform delay gives two IDX whenever the first two draws land within one message latency of each other. In the simulator (`addon/spec/helpers/sim.lua`, 100 trials each), uniform delays gave exactly one IDX in 87% of HELLOs at 0.05–0.25 s latency and 54% at 0.2–0.6 s, short of the Phase 3 target of 90%. Ranked delays gave 100% at both.
3. The winner, B, sends `IDX` covering only the mismatched buckets.
4. A diffs: it sends `PUT` for notes where A is newer and `NEED` for notes where B is newer.
5. B answers `NEED` with `PUT`s. The digests now match.

### 5.5 Lockdown gate

- Before every send, check the client's outgoing-addon-message restriction, and also treat a "restricted" `SendAddonMessage` result as lockdown. The check is `C_ChatInfo.InChatMessagingLockdown()` (spike 01, 1.60.1: false while idle). `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()` exists too but reads true while idle and sends succeed, so the gate never uses it. A check that raises an error counts as open; the send result still catches a real restriction.
- While restricted, messages wait in the outbox (`Core/Outbox.lua`). Queued items coalesce by key: live `PUT`s for a board merge their note ids, and are built at send time from the board as it is then, so repeated edits to a note send once, with the newest text. The outbox is pumped every 0.5 s; a refused send holds it for 2 s. Once the gate opens it flushes, and every board sends a fresh `HELLO`.
- The outbox also models the throttle (§5.6) as a token bucket in addon messages: 8 tokens, refilled at 0.9 per second, a little under the §2 estimate. A partial spike 02 on 1.60.1 saw no client-side rejection for WHISPER bursts, so this is conservative; raise it only if sync feels slow. A message needs one token to start and spends one per chunk, possibly going into debt.
- The gate is not driven by encounter start/end flags, so it can't get stuck closed. Local editing is never blocked.

### 5.6 Throttle budget and the bulk rule

At about 255 bytes/sec per prefix, and with other traffic sharing that budget, P2P catch-up only suits small deltas.

- **Estimate first.** The responder estimates the transfer from the bucket diff: for each mismatched bucket, the larger of the bytes of its own notes there and the requester's note count (HELLO `kc`) times about 150 bytes. A note counts as about 150 bytes or its text length, whichever is larger, so a bucket holding 2 KB recipe lists (§9.2) isn't priced like short notes. (The v0.2 plan had the requester estimate, but only the responder sees both sides' counts before any IDX is sent.) A responder that finds itself the more out of date also sends its own HELLO, so it catches up under its own cloud setting.
- **Small deltas go P2P.** If the estimate is ≤ 8 KB (about 30 s of budget), sync peer-to-peer.
- **Large deltas go to the cloud.** If the estimate is larger and the requester is cloud-enabled, the responder sends a partial IDX with only its newest 20 notes in the differing buckets, and the requester pulls those. It then shows a banner: "N notes behind. The companion will fetch the rest, then /reload." The companion handles the rest. **Cloud-enabled** means the companion has actually synced this board in the last 7 days (`sync.lastCloudAt`), not just that `board.cloud` is on: a new member without the companion would otherwise never catch up.
- **No cloud available.** If the client isn't cloud-enabled, full P2P sync still runs, at `"BULK"` priority (IDX, NEED and PUT alike), spread over time.
- Live edits always go P2P immediately; they're tiny.

---

## 6. Links and sanitisation

- Shift-click inserts a link into the focused note editor by post-hooking link insertion with `hooksecurefunc` (never pre-hooks or overrides).
- Notes render in a hyperlink-enabled frame: `OnHyperlinkEnter` shows `GameTooltip:SetHyperlink`, and `OnHyperlinkClick` calls `SetItemRef`.
- **Sanitise on receipt, identically in Lua and Python:**
  - Allowed hyperlink types: `item, quest, spell, achievement, currency, mount, battlepet, journal, enchant, trade`. `enchant` is a recipe and `trade` a whole profession (§2); both were added on 2026-09-26 with the Professions tab (§9.2).
  - Reject `|T`/`|A` textures and `|K` tokens.
  - Allow `|c…|r` colours.
  - Maximum 2,000 bytes per note.
  - A note that fails is dropped, not repaired.

  The sanitiser is a yes/no check, never a rewrite. A client that repaired a note would store different bytes under the same `(rev, editor)`, and the digest can't see that. The escape grammar is a whitelist:
  - `||`;
  - `|cAARRGGBB`, `|cnNAME:` (named colours such as `|cnIQ4:`, which modern item links may use) and `|r`;
  - `|H<type>:<data>|h<text>|h`, where `<type>` is an allowed type and neither part contains `|`.

  Any other `|` escape fails, including `|T`, `|A`, `|K` and `|n`. Text must also be strict UTF-8, with no control characters other than `\n`.

  Records are checked as well. Note ids must be `<8 lower-case hex>-<digits>`, 18 bytes at most. Names must look like `Name-Realm`, 64 bytes at most, with no `|` or control characters. Board names (BoardMeta) must be 1–64 bytes of strict UTF-8 with at least one non-space character, and no `|` or control characters at all. `color` must be 1–8 (the UI uses 1–5), `deleted` must be a boolean, `kind` must be absent, `"gear"`, `"recipes"`, `"quests"` or `"player"` (reason `kind`, checked after `deleted`), and a tombstone's text must be empty. Unknown fields are ignored, so notes from a newer client still load.

  `shared/test-vectors/sanitise.json` fixes the rules and the reason codes.
- Item and quest IDs are the ones valid on Forever. Links are built by the client, so no ID tables are needed.

---

## 7. Cloud path

### 7.1 Companion app

- **Stack:** Python 3.12 + PyInstaller single exe (Windows first; macOS later, since Forever ships on Mac).
- **Install discovery:** find the WoW root (the default Windows paths, the Mac `/Applications/World of Warcraft`, or a user-picked folder). Then pick the product subfolder that contains `Interface/AddOns/Corkboard`, preferring the Forever product. Identify the product from its flavor metadata file if present; otherwise ask once and store the choice. Handles `_classic_beta_` now and the unknown live folder later.
- **Read:** `WTF/Account/*/SavedVariables/Corkboard.lua`, parsed with a data-only Lua table parser (no `exec`). Only boards with `cloud = true` are read.
- **Triggers:** SavedVariables mtime change (logout or `/reload`), plus a pull every 10 min.
- **Sync:** `POST https://corkboard.<domain>/v1/boards/{id}/sync` with every local record the server doesn't hold in that version, plus the stored cursor, then pull pages until `more` is false. The companion keeps its own copy of the server's rows (up to its cursor) in its state file, so "doesn't hold" is an exact comparison. (Changed from "every note whose `rev > lastPushedClock`": that misses a note with an older rev that reaches this player over P2P after a push, when its author has no companion.) Records go in batches of about 48 KB to stay under the 64 KB request limit. The same board in two accounts on one install is merged first.
- **Register and rotate:** a 401 on sync means an unknown board or a wrong secret. The companion tries to register the board; a 409 means someone rotated, so it tries `rotate` with each of the board's `oldSecrets` (up to 5, kept by the addon) to move the server to the current secret. If none works, the board is marked "secret refused: rejoin with a new invite".
- **Write back:** regenerate `Interface/AddOns/Corkboard_Cloud/Data.lua` with the rows the SavedVariables don't have yet (§7.2). This is its own tiny addon (TOC `16001`, `## Dependencies: Corkboard`) so updates to the main addon don't wipe it. The file is written atomically (temp file + rename).
- **Never** write to SavedVariables. Warn if the WoW process is running, since cloud data only appears after the next `/reload`.
- **Implementation:** `companion/corkboard_companion`, standard library only (urllib for HTTP) plus `corkcore`. `luadata.py` is the data-only Lua parser: assignments of strings, numbers, booleans, nil and tables, and nothing else. Commands: `setup`, `status`, `sync` and `watch` (poll SavedVariables mtimes every 5 s, sync 3 s after a change, and pull every 10 minutes); with no command it runs setup the first time and watch after. Its config and state live in the user's config folder, never in the WoW folder.

### 7.2 Addon side

At `PLAYER_LOGIN`, merge `CorkboardCloudData` into `CorkboardDB` using the §4.3 rules and record `lastCloudAt` and `cloudCursor`. Merging is idempotent, so a stale `Data.lua` is harmless. Boards this account doesn't hold are ignored. `Core/Cloud.lua` implements it, and the format is:

```lua
CorkboardCloudData = {
  version = 1,
  written = 1790000000,            -- when the companion wrote the file (unix time)
  boards = {
    [boardId] = {
      cursor   = 1234,             -- the API sequence number the companion has reached
      syncedAt = 1790000000,       -- when (becomes sync.lastCloudAt)
      notes    = { Note, … },      -- rows newer than (or missing from) the SavedVariables the companion last read
      members  = { MemberRecord, … },
      meta     = BoardMeta,        -- or nil
    },
  },
}
```

### 7.3 Sync API

- **Stack:** FastAPI + SQLite (WAL) in one container.
- **Auth:** `Authorization: Bearer <boardId>.<secret>`. The server stores `sha256(secret)` and compares in constant time.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/boards` | Register `{id, secret}`. 409 if it exists. |
| `POST` | `/v1/boards/{id}/sync` | `{cursor, notes[], members[], meta}` → merge, then return rows changed since `cursor`, plus the new cursor. `meta` is returned when it changed since `cursor`. |
| `POST` | `/v1/boards/{id}/rotate` | Owner rotates the secret: body contains the new secret; auth uses the old one. |
| `GET` | `/v1/health` | Liveness and DB check. |

```sql
boards  (id TEXT PK, secret_hash BLOB, created_at INT, seq INT NOT NULL DEFAULT 0,
         name TEXT, name_rev INT, name_editor TEXT, name_seq INT);   -- BoardMeta
notes   (board_id TEXT, note_id TEXT, author TEXT, created INT, rev INT, editor TEXT,
         text TEXT, color INT, deleted INT, seq INT, kind TEXT,  -- kind: NULL, "gear" (§9.1), "recipes" (§9.2), "quests" (§9.3) or "player" (§9.4)
         PRIMARY KEY (board_id, note_id));
members (board_id TEXT, name TEXT, role TEXT, rev INT, editor TEXT, removed INT, seq INT,
         PRIMARY KEY (board_id, name));
CREATE INDEX notes_seq ON notes(board_id, seq);
```

- **Merge:** in one transaction, upsert when the incoming record wins under §4.3 (`(rev, editor)`, then the exact-tie rule), and assign `seq = ++boards.seq` to each accepted row.
- **Limits:** 1,000 notes per board, 2,000 bytes per note, 64 KB per request, 60 requests/min per board, 20 board registrations/hour per IP.

### 7.4 Web app (PWA)

Added on 2026-09-27 at Will's request: the boards on a desktop browser or a phone, looking as close to the in-game window as a web page can. It's a client of the sync API like the companion, so the addon, the API and the merge rules don't change.

- **Where:** `web/public/`, plain ES modules with no build step. Caddy serves it at `https://corkboard.<domain>/` next to the API's `/v1/` (§8), so requests are same-origin and the API needs no CORS. Installable as an app (manifest, icons, a service worker that caches the app itself, never board data or API responses). For a local run the API serves it too when `CORK_WEB` points at the folder.
- **Signing in:** a board's invite string (§9), which carries the id and secret the API wants (`Bearer <boardId>.<secret>`), plus a free-text name. Records need `Name-Realm` (§6), so a name typed without a realm is signed `Name-Web`, which also tells members in game where the note came from; a name typed with a realm is used as it is, so a player can post as their character. The name is per device and can be changed. Joining doesn't add a MemberRecord: the roster stays the characters who joined in game.
- **Storage:** IndexedDB in the browser: each board's records, clock, API cursor and unsent changes. A private window that has no IndexedDB keeps them in memory and says so. "Leave" removes a board from the device only, like deleting one in game (§4.1).
- **Note ids:** a random 8-hex-digit prefix per device (the game derives it from the character's GUID, which the web has none of), then the counter rule of §4.2. So two devices never share a counter.
- **Merge core:** `web/public/js/core/` is the JavaScript port of `Merge`, `Digest`, `Sanitise` and `Invite`. It passes every case in `shared/test-vectors/`, the fuzz corpus included, plus the same convergence properties as the Python suite. Strings are measured and compared as UTF-8 bytes, never UTF-16 units. Local changes use the §4.3 clock with the device's time, like any client.
- **Sync:** `POST /v1/boards/{id}/sync` with the device's unsent records and its cursor, then pages until `more` is false, applying every row with the merge core. A 401 tries `POST /v1/boards` as the companion does (§7.1): 201 means the board was new to the server, 409 that the secret is wrong, which the app shows as "Invite out of date" and stops polling until the invite is entered again (polling would spend the per-IP registration limit). The board on screen syncs every 30 s while the page is visible, others every 5 minutes, and a local change goes 0.8 s after it's made. Offline, changes wait and the status line counts them. A record the server merged is no longer pending, whether it won or lost to a newer one.
- **What it shows:** the six tabs from the game (§9) with the game's rules and wording: Notes (search, New Note, edit, delete, tags), Members (the invite with a Copy button, the roster, the board digest as `/cork debug` prints it), Gear, Professions, Quests and Players (add, edit and delete player notes in the `P1;` format of §9.4). Board list: Join, Rename (a BoardMeta edit), Leave.
- **Links:** notes render with their colour codes; a link shows a GameTooltip-style box with its name, kind and id (the web has no item data). The editor is a text box where links read `[Name]`: an existing link keeps its exact bytes, and **Link…** lists every link on the board to insert, standing in for shift-click. A typed `|` becomes `||`, as the game's edit boxes write it. Colour codes that don't wrap a link are dropped when a note is edited on the web (the editor says so). Quest and recipe names come from links seen on the board; otherwise they show as "Quest #id" and "Recipe id".
- **Not on the web:** anything that needs the game: gear posts, recipe scans, quest logs, the unit tooltip and group warning, creating a board, rotating the secret and removing members (both owner-only and tied to the channel, §10), and the sync options (they're per-install settings of the addon).
- **Delay to the game:** what the web writes reaches a player's client when their companion syncs the board and they `/reload` (§7.2), and spreads from there over P2P. Game edits reach the web once a companion has pushed them.

---

## 8. Hosting: Arcane + public DNS

```
Internet ─► corkboard.<domain> (public DNS) ─► :443 on host ─► caddy ─► api:8000
                                                                     └─ /data (volume: SQLite + backups)
Arcane dashboard stays tailnet-only (harry.alpine-ionian.ts.net) — never exposed.
```

**Compose stack (deployed as an Arcane project):**

```yaml
services:
  api:
    build: { context: ., dockerfile: api/Dockerfile }   # built on the host from the uploaded workspace
    image: corkboard-api:latest
    restart: unless-stopped
    environment:
      CORK_DB: /data/corkboard.db
      CORK_TRUSTED_PROXY: caddy
    volumes: [corkboard-data:/data]
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://localhost:8000/v1/health')"]
      interval: 30s
    networks: [internal]
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes: [./Caddyfile:/etc/caddy/Caddyfile:ro, ./web/public:/srv/web:ro, caddy-data:/data]
    networks: [internal]
  backup:
    image: alpine
    command: ["sh","-c","apk add sqlite && while true; do sqlite3 /data/corkboard.db \".backup /data/backup-$$(date +%a).db\"; sleep 86400; done"]
    volumes: [corkboard-data:/data]
volumes: { corkboard-data: {}, caddy-data: {} }
networks: { internal: {} }
```

```caddyfile
corkboard.<domain> {
  request_body { max_size 64KB }
  header { Strict-Transport-Security "max-age=31536000" -Server }
  handle /v1/* { reverse_proxy api:8000 }
  handle {                      # the web app (§7.4)
    root * /srv/web
    header Content-Security-Policy "default-src 'self'; … frame-ancestors 'none'"
    file_server
  }
}
```

- **DNS/TLS:** an A (or CNAME) record for `corkboard.<domain>` pointing to the host's public IP. Caddy gets a Let's Encrypt certificate automatically, which needs ports 80 and 443 reachable. If the host sits behind CGNAT or you'd rather not open ports, swap Caddy's public ports for a Cloudflare Tunnel sidecar pointing at `api:8000`. Nothing else changes.
- **Exposure:** only this hostname and 443 (plus 80 for the ACME challenge). Arcane, SSH and other services stay tailnet-only.
- **Images:** Arcane builds the API image on the host from the project workspace, which `tools/arcane_deploy.py` uploads (like the `ballot` project), so no registry is involved. CI still builds and smoke-tests the image on pull requests.
- **Backups:** 7 rolling daily SQLite snapshots in the volume. Optionally Litestream to S3 or MinIO later.
- **Logging:** access logs never include the `Authorization` header. The app logs board id, route, status and latency only.

---

## 9. UI

- **Board list:** name, members, who's online (from recent HELLOs), and a sync badge such as "P2P: Bob 3m ago · Cloud: 2h ago", "Queued (restricted)", or "N behind: /reload after cloud sync".
- **Tabs:** Notes, Members, Gear (§9.1), Professions (§9.2), Quests (§9.3) and Players (§9.4) along the bottom of the window.
- **Board view:** sticky-card grid (colour, author, relative time, live links).
- **Editor:** multiline EditBox, shift-click links, character counter, colour picker. The counter counts bytes, since the sanitiser's 2,000 limit is in bytes. Save stays disabled while `Sanitise.text` would reject the text, and the editor says why. An unchanged save writes nothing, so it doesn't bump the rev and resend the note.
- **Share:** "Copy invite" produces `CORK1:<base64(boardId|secret|ownerName)>`. "Join" takes a pasted string.
- **Slash commands:** `/cork`, `/cork join <invite>`, `/cork invite`, `/cork members`, `/cork remove <Name-Realm>`, `/cork rotate`, `/cork cloud on|off`, `/cork guild on|off`, `/cork sync` (HELLO on every board now), `/cork debug`, `/cork minimap` (show or hide the minimap button), `/cork quests [name]` and `/cork quests on|off` (§9.3), and `/cork player <name>` (§9.4).
- **Opening the window:** `/cork` with nothing after it, the addon compartment by the minimap (`## AddonCompartmentFunc`), the LibDataBroker launcher in a broker display, or the minimap button (LibDBIcon). The button starts at LibDBIcon's default spot on the rim, can be dragged round it, and keeps its angle and hidden state in `CorkboardDB.global.minimap`.
- Boards and notes are created, renamed, edited and deleted in the window only. (The Phase 1 store commands, `/cork create`, `add`, `list` and the rest, were removed once the window covered them; the specs drive the store directly instead.) Command output goes to the default chat frame with a gold `Corkboard:` prefix.
- Works with Forever's modern and Classic visual presets (no reliance on retail-only art atlases; verify in Phase 1).

### 9.1 Gear feed

Added on 2026-09-26 at Will's request. When a member equips a rare (blue) or better item for the first time on that character, the board shows "Will equipped [Tidal Charm]" on a third window tab, **Gear**, newest first (the latest 50).

- **Records.** A gear entry is a Note with `kind = "gear"` and the item link as its `text`, so it rides every existing path unchanged: live PUTs, anti-entropy, the digest, the cloud and the API. Only the sanitiser and the tie-break learned the field (§4.3, §6). A separate record type would have needed its own digest, messages, API table and companion handling for no gain. `Store.notes` leaves gear entries out, and `Store.gear` lists only them.
- **Detection** (`Corkboard.lua`): `PLAYER_EQUIPMENT_CHANGED` for slots 1–19. The link comes from `GetInventoryItemLink`, the quality from `GetInventoryItemQuality`, or failing that `C_Item.GetItemQualityByID`. A secret link or quality is ignored.
- **First time only.** Each character keeps the item ids it has equipped in `CorkboardDB.char.gearSeen`. At login, and again once the player's name is known, everything already worn is marked seen without posting, so only later upgrades post and swapping gear back and forth posts nothing.
- **Which boards.** Every board on the account with `gear ~= false`, skipping boards that removed the player. The option is local and on by default; the Gear tab has a checkbox for it. Boards whose channel isn't active get the entry through anti-entropy or the cloud later.
- **Volume.** Blue and better only, once per item per character: tens of entries per character over a levelling run, well under the API's 1,000-row cap. Entries count towards that cap like notes.
- **Older clients** ignore `kind` (unknown fields are dropped), so they show gear entries as ordinary notes. Only dev builds exist before launch, so this is accepted. On an exact `(rev, editor)` tie the copy with a kind wins, so a newer client never loses it to a relayed copy without one.

### 9.2 Professions tab

Added on 2026-09-26 at Will's request, after the in-game probes in §2. Each member's learned recipes are shared with their boards, and the **Professions** tab (the fourth) answers "who can make this?".

- **Records.** One Note per character and profession, with `kind = "recipes"`, so like the gear feed it rides every existing path unchanged. Its text is plain, with no escapes, so it needs no sanitiser special case:

  ```
  R2;<professionID>;<skill>;<max skill>;<learned>;<profession name>
  <recipe ids, ascending, in base 36, each after the first written as the gap from the one before>
  <one token per id on the line above: the crafted item's required level in decimal, then c, l, m or p for cloth, leather, mail or plate armour; empty when unknown>
  ```

  For example `R2;165;47;75;8;Leatherworking`, then `r2lj,1,4,…`, then `,5l,3l,…`. The third line is left out when no recipe has details, and when the list doesn't fit, ids and their tokens are cut together. `R1` lists (before 2026-09-27) are the same without the third line and still read. Recipe ids are 7 digits on Forever (§2), and the gaps between one profession's ids are mostly one to three base-36 digits, so a 2,000-byte note holds several hundred recipes. `learned` is the full count: if the list ever doesn't fit, the ids that fit are kept and the tab says how many are shown. Profession names hold no `;`, `|` or line breaks and are at most 64 bytes. A note whose text doesn't parse is ignored by the tab (it still syncs, like any note).
- **Reading.** The profession API only answers while that profession's window is open (§2). The addon marks a scan as wanted on `TRADE_SKILL_SHOW`, `TRADE_SKILL_DATA_SOURCE_CHANGED` and `NEW_RECIPE_LEARNED`, then scans once `C_TradeSkillUI.IsTradeSkillReady()` is true (usually on the next `TRADE_SKILL_LIST_UPDATE`): `GetBaseProfessionInfo()` for the profession, and `GetAllRecipeIDs()` filtered on `GetRecipeInfo(id).learned`, leaving out dummy, recraft, salvage and gathering entries. Each recipe's `hyperlink` (the crafted item) gives its details: `C_Item.GetItemInfoInstant` for the armour type (item class Armor, subclass Cloth, Leather, Mail or Plate; a cloak counts as none, since anyone wears one), and `C_Item.GetItemInfo` for the required level (only when 1 or more). An item the client hasn't loaded has no level yet; asking starts the load, so the scan runs again 3 s later, at most twice per window opening, and shares the levels it then has. A recipe that doesn't make an item (an enchant) has no details. It doesn't scan on every `TRADE_SKILL_LIST_UPDATE`, which fires on each craft: re-sending a 2 KB list per skill-up would hog the throttle (§5.6), so the skill shown refreshes next time the window opens. A linked, guild or NPC profession view is skipped, so nobody posts someone else's recipes as their own. Secret values are skipped.
- **Writing.** The last scan of each profession is kept per character in `CorkboardDB.char.professions` (profession id → encoded text), and shared to every board with `recipes ~= false` that hasn't removed the player: the character's existing entry for that profession is edited (only if the text changed), or one is created. Extra copies of the same character and profession (two installs) are deleted. Sharing runs after each scan, at login, and when a board is created, joined or has the option turned on, so a new board gets the recipes without reopening every profession.
- **Opting out.** The option is local and on by default, with a checkbox on the tab. Turning it off deletes this character's recipe entries on that board; turning it back on shares the kept scans again.
- **Filters** (added on 2026-09-27 at Will's request). Under the top row, a **Level** range (two number boxes, either may be empty) and **Cloth**, **Leather**, **Mail** and **Plate** checkboxes. Either narrows the tab to matching recipes from every member, like a search, and combines with one: a level bound leaves out recipes of unknown level, and ticked armour types leave out anything else. Each recipe row shows its details ("Level 25 · Leather") between the link and who knows it. The filters are local and last the session. Recipes from `R1` lists, or from members whose items hadn't loaded, have no details and only show while no filter is set.
- **Showing.** With an empty search the tab lists each member's professions ("Leatherworking 47/75 · 8 recipes"). Clicking one opens the recipes it holds under it, sorted by name, and clicking again closes it (changed on 2026-09-27: until then the recipes only showed through a search, so members couldn't see what someone could make without guessing a name). Which professions are open is local to the session, per board. A search lists matching recipes, each with the members who know it; every word must appear in the recipe's name, its profession or a knower's name, so searching a member's name lists their recipes. Recipes show as `enchant` links built locally: `|cffffd000|Henchant:<id>|h[<name>]|h|r`, named by `C_Spell.GetSpellName` (the recipe id is the craft's spell id), falling back to `GetSpellInfo` and then "Recipe <id>". At most 200 rows show.
- **Mixed versions.** A client from before the `R2` format ignores `R2` lists, so its Professions tab goes empty until it updates (the notes still sync). Only dev builds exist before launch, so members update together. A client from before this change drops recipe lists (sanitiser reason `kind`) and notes holding `enchant` or `trade` links (`link_type`), so its digest never matches a newer member's and anti-entropy keeps offering it those notes. The API needs the same update before the companion can push them. Only dev builds exist before launch, so members update together.
- A profession with no learned recipes (Fishing, say) still posts its header, so the tab shows its skill.
- **Not handled in v1:** a profession the character drops keeps its entry (and its kept scan). `GetProfessions` could prune these at login, but it hasn't been checked in game, and pruning on a wrong answer would delete real entries.

### 9.3 Quest logs

Added on 2026-09-26 at Will's request, to answer "what quests are you on?". Each member's quest log is shared with the board, and a fifth window tab, **Quests**, shows it member by member.

- **Records.** A character's quest log is one Note with `kind = "quests"`, so like the gear feed it rides every existing path unchanged. Its id is the character's note-id prefix with counter 0 (`a1b2c3d4-0`), which `Store.nextNoteId` never hands out. So the log can't take a real note's id, even when an install that hasn't synced the board yet publishes it, and every install of the character writes the same record: last-writer-wins keeps exactly one log per character. `Store.notes` and `Store.gear` leave it out; `Store.questLogs` lists them.
- **Format.** The text is `id:level` pairs joined by commas and sorted by id, for example `7:5,46:10,166:18`. That's plain text, so the sanitiser needs nothing new. Titles don't travel: full quest links run to about 60 bytes each, and Forever's 40-quest log would pass the 2,000-byte note limit, while ids and levels need about 400 bytes. At most 50 quests are kept (`Store.QUESTS_MAX`). Each client names quests from its own quest data (`C_QuestLog.GetTitleForQuestID`, loading unknown ones with `RequestLoadQuestByID`) and shows "Quest #id" until the name arrives. The links on the tab are built locally and never stored.
- **Detection** (`Corkboard.lua`). `QUEST_LOG_UPDATE`, `QUEST_ACCEPTED`, `QUEST_REMOVED` and `QUEST_TURNED_IN` schedule one read of the log 2 s later, since they come in bursts. Headers and hidden entries are skipped, and a secret value anywhere drops that read. Nothing is read before the client's first `QUEST_LOG_UPDATE` of the session, when the log can still look empty: publishing it then would briefly wipe the member's list for everyone. An unchanged log writes nothing, so objective progress (which fires `QUEST_LOG_UPDATE` on every kill) sends nothing.
- **Which boards.** Every board with `quests ~= false`, skipping boards that removed the player. The option is local and **on by default**, like gear; the Quests tab has a checkbox for it, and `/cork quests on|off` sets it for the current board. Unticking it deletes the log (a tombstone). Ticking it again writes a newer live version of the same record, which beats the tombstone under plain LWW (§4.3, the "a later edit beats a tombstone" vector). A board that's created or joined gets the log straight away. The character's own log is also kept locally in `CorkboardDB.char.quests`, so the tab can mark shared quests on boards where you don't share yours.
- **The tab.** On the left, the members sharing a log: others by name, then you, each with their quest count and how many you share. On the right, the chosen member's quests by level, then title: a live link (tooltip on hover, click-through), the level, and a ready-check tick on each quest you're on too. The header says how current the list is: "online now" while the member is online (heard from in the last 13 minutes), otherwise "as of 2h ago", from the later of the log's `rev` and when the member was last heard from. A running client republishes as soon as the log changes, so that's the time the list was last known to be right. "Only quests I'm on too" filters the list. Clicking a member on the Members tab opens their log here.
- **Chat.** `/cork quests` lists who shares a log on the current board, with counts. `/cork quests <name>` prints that member's quests with the same ticks. The name can be the whole `Name-Realm`, the part before the realm, or the start of either, in any case.
- **Volume.** One live record per character per board, rewritten in place, so rows don't pile up against the API's 1,000-row cap. Each accepted, abandoned or completed quest costs one PUT.
- **Older clients** show the log as an ordinary note of numbers, as with gear. Accepted for the same reason.

### 9.4 Player notes (avoid and good players)

Added on 2026-09-27 at Will's request: a place on each board to note a character by name, say what they did, and mark them as someone to **avoid** or a **good player**. A sixth window tab, **Players**, lists them, and the addon brings them up where they matter: on the player's tooltip and when they join your group.

- **Records.** An entry is a Note with `kind = "player"`, so like the other kinds it rides every existing path unchanged: live PUTs, anti-entropy, the digest, the cloud and the API. Only the sanitiser learned the kind. Its text is a header line, then the reason:

  ```
  P1;<verdict>;<character name>
  <why, free text with links, optional>
  ```

  For example `P1;avoid;Gankalot` then `Rolled need on [Tidal Charm] and left.` The verdict is `avoid` or `good`. The name is as typed or taken from the target, tidied (spaces trimmed and collapsed; a pasted line break becomes a space), 1–64 bytes with no `;`, `|` or control characters, and a letter or digit in the first word. The whole text must pass `Sanitise.text` like any note, so the reason can hold item, quest and spell links. A header this client doesn't understand (a verdict from a newer client, say) is left off the tab and out of the lookups; the note still syncs.
- **Entries are notes.** Each entry has its own note id, so several members can note the same character, and each shows with its author. Any member can edit or delete any entry, as with notes (§14.3). Deleting leaves a tombstone. `Store.notes` leaves entries out; `Players.entries` lists them.
- **Matching.** Entries are matched on the character's first name, ASCII lower-cased: the first word before any space (a Forever surname, §2) or `-` (a realm). Units, chat and typed names don't agree on whether the surname or realm is there, and the first name is the part every form shares. Two characters on different realms can share a first name, so the tab, tooltip and chat always show the name as written, realm and all when it was given.
- **The tab.** Two checkboxes, **Avoid** and **Good players** (both ticked), a search box and **Add Player** across the top, then a short grey description of what the tab is for. Below, one row per entry, by name and then newest first: a ready-check cross or tick, the name and the verdict in the game's red or green, "author · age" on the right (Edit and Delete in its place on hover, as on note cards), and the reason under it in `ChatFontNormal` with live links. A search matches every word against the name, reason, verdict and who wrote or edited the entry. The count at the bottom reads "2 to avoid · 3 good players".
- **The editor.** A small window: **Character** (with a **Target** button, and filled from the target when you open it while targeting a player), **Avoid** or **Good player**, and **Why**, a multi-line box that takes shift-clicked links. The byte counter counts the whole entry. Save stays disabled until the entry would pass the sanitiser, and says why not. An unchanged save writes nothing.
- **Tooltips.** Hovering a player adds a line per entry on any of your boards (avoid entries first, at most 3, then "and N more notes"): "Corkboard: Avoid" in red, or "Corkboard: Good player" in green, with "author · board" on the right, and the reason as plain text cut at 120 bytes. The entries are indexed by first name once and the index is rebuilt after any change to the store, so hovering costs a table lookup.
- **Group warning.** When the group changes (`GROUP_ROSTER_UPDATE`, checked once a second after a burst), each other member is looked up. A player with an avoid entry prints one chat line per session, "Gankalot is in your group. Avoid: why (Will on Raid, 2d ago)". Good players print nothing. Leaving the group resets it, so the next group they turn up in warns again.
- **Chat.** `/cork player <name>` prints every entry about that player on all your boards.
- **Every board.** The tooltip, the warning and `/cork player` use every board on the account, not just the selected one. There's no per-board option: an entry is something a member chose to write, not something the addon shares on its own.
- **Volume.** One row per entry. Entries count towards the API's 1,000-row cap like notes.
- **Older clients** drop player entries (sanitiser reason `kind`), as with recipe lists (§9.2): their digest never matches, and anti-entropy keeps offering them the entries. Only dev builds exist before launch, so members update together.
- **Not in v1:** adding a player from the unit right-click menu (it needs Mainline's `Menu.ModifyMenu`, not yet checked on Forever), and turning the tooltip line or the group warning off.

---

## 10. Trust model and risks

- **Membership = holding the secret.** Revoking someone means rotating the secret (new channel password and cloud credential), then re-sharing it with the remaining members.
- **Transport identity is server-verified; relayed authorship is not.** A malicious member could forge `author`. This is accepted for v1.
- **Player notes are opinions** (§9.4). They are only as good as the member who wrote them, which is why each shows its author. They stay inside the board: only members (and the board's cloud copy) hold them, and nothing is ever sent to the player or posted in public chat.
- **The web app holds the secret.** A device that signed in keeps the board's secret in browser storage, as the companion keeps it in its config. Anyone with the device has the board; rotating the secret (§10, first bullet) shuts them out. The page runs no third-party code, sets a strict Content-Security-Policy, and renders board text as text nodes, never HTML.
- **Web names are unverified,** like relayed authorship: anyone with the invite can sign as any name, `-Web` or a character's. Accepted for v1, for the same reason.
- **Public API surface:** auth on every board route, strict size and rate limits, the same sanitiser as the addon, and no admin endpoints.
- **Platform risk:** Forever is pre-launch. API names, restrictions, the throttle and the install layout can all change before and after 2026-11-04. Re-run the Phase 1–4 in-game checks at launch.

---

## 11. Testing

- The merge, digest and sanitiser code is pure Lua 5.1 (no WoW API), tested with `busted`.
- Shared JSON test vectors run in the Lua tests, pytest and the web app's `node --test` suite.
- The web app has its own end-to-end test: the real API serving the app, driven in headless Chromium on desktop and phone viewports (`web/e2e/`).
- Hypothesis property tests: random edits, deletes, and reordered, duplicated or dropped deliveries across 3–5 simulated nodes plus a simulated server must converge to the same digest.
- A throttle simulator (1 msg/s per prefix, burst of 10) validates the bulk-rule thresholds before in-game testing.
- The `/cork debug` panel shows outbox depth, throttle stalls, gate state, bucket diffs, and last HELLO per member.

---

## 12. Phases and acceptance criteria

**Phase 0: Forever spikes (dropped on 2026-09-26)**

Will dropped the spikes after a first in-game run on the 1.60.1 beta: the main addon is tested directly instead. What that run found (the gate check, the result codes, Forever's surnamed player names, the client's division-by-zero error) is in §2, §5.5 and `docs/next-steps.md`. The items below stay as a record of what the spikes were meant to answer.

- [ ] Exact outgoing-restriction API on 16001, when it's true (encounters, death, anything else), and the `SendAddonMessage` result codes.
- [ ] Measured per-prefix throttle (burst, sustained rate), and whether whisper, channel, guild and BNet share one budget.
- [ ] Password-protected custom channel reach on Forever realms (same realm, connected realms, cross-realm), and the per-character channel limit.
- [ ] Hyperlinks survive the LibDeflate addon-channel round trip intact.
- [ ] `BNSendGameData` works on Forever: payload size and throttle.
- [ ] SavedVariables fresh-launch bug status. Product and folder identification for the companion.

**Phase 1: Local boards**
- [ ] Create, rename and delete boards. Add, edit and delete notes with colour and links. Tooltips on hover, and clicking opens the item or quest.
- [ ] State survives `/reload` (and a full relog once the beta bug is fixed).
- [ ] Merge-core coverage ≥ 95%. All shared test vectors pass in Lua.

> **Status, 2026-09-26:** Phases 1–6 are built, but no box below is ticked: each needs its evidence from the Forever client (or the live host). What already passes outside the game is noted under each phase; `docs/next-steps.md` has the in-game checklists and the assumptions to check.

**Phase 2: Live P2P**
- [ ] Invites round-trip. The hidden channel never shows in any chat frame.
- [ ] With 2 clients online, an edit appears on the other client within 5 s.
- [ ] Non-member traffic is ignored, and secret payloads are dropped without errors.

  *Outside the game:* all three pass between fake clients running the real addon (`addon/spec/net_spec.lua`) and in the simulator (`sync_spec.lua`).

**Phase 3: Anti-entropy**
- [ ] With A offline, B makes 20 creates, 5 edits and 3 deletes. After A logs in, the digests match within 60 s via P2P, and the debug panel shows only mismatched buckets were exchanged.
- [ ] Deleted notes never reappear, including when a stale third client logs in.
- [ ] Concurrent edits to the same note converge to the same winner on 3 clients.
- [ ] With 5 members online, a HELLO triggers exactly one IDX in ≥ 90% of trials.

  *Outside the game:* all four pass in the simulator (`sync_spec.lua`; 30 of 30 trials for the IDX count), plus a 25-seed churn property (`sync_property_spec.lua`). The debug panel exists but hasn't been seen in game.

**Phase 4: Hardening**
- [ ] Edits during an encounter (and while dead) are queued and delivered within 10 s of the gate opening, with no Lua errors or `ADDON_ACTION_FORBIDDEN`.
- [ ] No message is ever lost to throttling (verified with result-code logging over a 500-note sync).
- [ ] The bulk rule triggers above 8 KB, and the banner shows.
- [ ] The sanitiser fuzz corpus is rejected identically in Lua and Python.

  *Outside the game:* the queue-and-deliver, throttle and fuzz items pass (`sync_spec.lua`, `net_spec.lua`, `sanitise_fuzz_spec.lua` with `shared/test-vectors/sanitise_fuzz.json`). The 8 KB rule and the banner pass in the simulator. The result-code logging over a real 500-note sync needs the client.

**Phase 5: Cloud + hosting**
- [ ] The stack deploys from Arcane. `https://corkboard.<domain>/v1/health` returns 200 over valid TLS from outside the tailnet, and the Arcane dashboard is unreachable from the internet.
- [ ] B edits and logs out. With nobody else online, A's companion syncs, then A `/reload`s and sees B's edits.
- [ ] A 500-note board catches up entirely via the cloud, with no P2P bulk traffic.
- [ ] Wrong secret gives 401, a rotated secret invalidates the old one, and rate limits return 429.
- [ ] The companion never writes SavedVariables, and `Data.lua` writes are atomic.
- [ ] A backup restore drill: restore yesterday's snapshot into a fresh stack, and the digests match.

  *Outside the game:* the API, the companion and the catch-up path pass in pytest, including the real addon (in the fake client) loading a `Data.lua` the companion wrote after syncing through the API. The deploy, TLS and drill items need the host (`infra/README.md`).

**Phase 6: Distribution**
- [ ] `Corkboard` + `Corkboard_Cloud` packages (interface 16001) on CurseForge and Wago, once they list the Forever flavour.
- [ ] Signed companion installer with a first-run wizard (finds the Forever install, sets the API URL).

  *So far:* `tools/package_addon.py`, `.pkgmeta` and `.github/workflows/release.yml` (GitHub release now; CurseForge and Wago once they list Forever and the tokens exist); a PyInstaller spec and a tkinter wizard, untested on Windows and macOS, and no signing certificate yet.

**Phase 7: Web app (§7.4)**
- [ ] The app is served at `https://corkboard.<domain>/` from the live host, installs as an app on a phone (iOS Safari "Add to Home Screen" and Android Chrome "Install"), and opens with no network.
- [ ] Signed in with an invite and a name, it shows a board's notes, gear, professions, quest logs and player notes as the game wrote them.
- [ ] A note written on the phone shows in game after the companion syncs and the player `/reload`s, signed `Name-Web`, with any link it holds working in game.
- [ ] A note edited in game shows on the phone within a minute of the companion pushing it.
- [ ] The JavaScript merge core passes every shared vector and the fuzz corpus.

  *Outside the game:* the last item passes (`web/test/`), and the end-to-end test covers the others against a local API: joining, every tab, writing notes and player notes, a reload, a queued offline edit, the app opening offline, a change pushed as a companion would, and the phone layout.

---

## 13. Dependencies

- **Addon:** from Ace3, LibStub, CallbackHandler, AceDB and ChatThrottleLib; then LibSerialize, LibDeflate, LibDataBroker and LibDBIcon. All must be current builds that load on modern-API clients. Corkboard frames its own messages (§5.2), so AceComm isn't carried. A frame on `ADDON_LOADED`/`PLAYER_LOGIN`, `SlashCmdList` and `C_Timer` replace AceAddon, AceConsole, AceEvent and AceTimer, which were listed here but had one trivial use each or none.
- **Companion/API:** Python 3.12, FastAPI, SQLite, a Lua-table data parser, Hypothesis, PyInstaller.
- **Web app:** no runtime dependencies; Marcellus and PT Sans Narrow (SIL OFL) are self-hosted. Node 20+ runs its tests, and Playwright drives Chromium for the end-to-end test.
- **Infra:** Arcane, Caddy 2, GHCR, GitHub Actions.

## 14. Decisions (formerly open questions)

Settled on 2026-09-26: Will accepted the v1 behaviour as built. Each can be revisited after launch without a format change.

1. **Reverse proxy:** the stack ships its own Caddy. If the host already runs a proxy on 80/443, drop the `caddy` service at deploy time and route the name to `api:8000` there (`infra/README.md`).
2. **Reachability:** a public IP with ports 80 and 443 forwarded is the default. Behind CGNAT, swap Caddy's public ports for a Cloudflare Tunnel sidecar (§8). Either is a deploy-time choice; the API doesn't change.
3. **Delete permissions:** any member may edit or delete any note. Only the owner removes members or rotates, and that's enforced in the UI and `/cork` only; the API lets any holder of the current secret rotate.
4. **Guild boards:** invite-only. Ticking the guild option moves the board's traffic onto GUILD instead of a channel (§5.1); guildmates still need the invite and its secret.
5. **Closing a board for everyone:** not in v1. Deleting a board stays local (§4.1).
6. **Re-sharing after a rotation:** manual. Nothing whispers (§5.1); the owner sends the new invite out of band, and members who missed it sit alone on the old channel until they get it.
7. **Tombstone collection:** none in v1. The API's 1,000-row cap includes tombstones; revisit only if a real board nears it.
