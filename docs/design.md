# Corkboard: Shared Post-it Boards for WoW: Forever

**Status:** Draft v0.2 · **Target client:** World of Warcraft: Forever 1.60.x (TOC `## Interface: 16001`, game type `camelot`) · **Addon prefix:** `CORK`
**Backend hosting:** Docker stack on Will's Arcane host, exposed on a public DNS name.

Corkboard is an addon for World of Warcraft: Forever. A player creates a board and shares it with an invite string. Everyone on the board can add free-text notes containing item, quest, spell and similar links. Boards sync between members peer-to-peer in game. A companion app and a self-hosted sync API let members catch up even when no other member is online.

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
| Combat and chat values can be **secret** in restricted contexts. `SendAddonMessage` refuses secret arguments. | Never send data derived from unit or combat APIs. Drop any received payload where `issecretvalue(msg)` is true. Corkboard only sends user-typed text, so this is a guardrail, not a limitation. |
| Outgoing addon messages are restricted during encounters, and briefly around death and resurrection too. | The lockdown gate polls the client's restriction check instead of tracking `ENCOUNTER_START`/`END` flags, which can get stuck (§5.5). |
| Addon messages have a **per-prefix throttle across all chat types**: roughly 1 message per second, with a small burst allowance. `SendAddonMessage` returns a result code. | About 255 bytes/sec sustained per prefix. P2P is for live edits and small deltas. Bulk sync goes through the cloud (§5.6). |
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
                                                    (Docker stack on Arcane)
```

The same **merge core** (§4.3) runs in the addon (Lua 5.1) and in the companion and API (Python). Shared JSON test vectors keep all three behaviourally identical.

---

## 4. Data model

### 4.1 Board

```lua
CorkboardDB.boards[boardId] = {
  id       = "k3f9x2m7q1pz8c4w",   -- 16 chars, random base36
  meta     = BoardMeta,            -- the board's name, replicated LWW (below)
  secret   = "…24 chars…",         -- shared by members: channel password + cloud credential
  owner    = "Will-Realm",
  created  = 1790000000,           -- GetServerTime()
  members  = { ["Name-Realm"] = MemberRecord, … },
  notes    = { [noteId] = Note, … },
  clock    = 0,                    -- highest rev seen (HLC-lite, §4.3)
  sync     = { lastPeer, lastPeerAt, lastCloudAt, cloudCursor },
  cloud    = true,                 -- companion sync on by default now the API exists
  guild    = false,                -- also use the GUILD transport
}
```

### 4.2 Note

```lua
Note = {
  id      = "a1b2c3d4-0007",   -- <8-char hash of author GUID>-<per-author counter>
  author  = "Will-Realm",
  created = 1790000123,
  rev     = 1790000456,        -- §4.3
  editor  = "Bob-Realm",       -- who produced this rev (tie-breaker)
  text    = "Need 4x |cff…|Hitem:…|h[…]|h|r for …",
  color   = 1,
  deleted = false,             -- tombstone; text cleared when true
}
```

`MemberRecord = { name, role = "owner"|"member", rev, editor, removed }` uses the same last-write-wins (LWW) rules as notes.

`BoardMeta = { name = "Molten Core prep", rev, editor }` is the board's name. The invite string carries only the id, secret and owner (§9), so the name has to replicate like any other record, and a rename is an LWW edit on the same board clock. A board holds one BoardMeta, not a map.

### 4.3 Merge rules

- **Clock:** on a local change, `rev = max(GetServerTime(), board.clock + 1)`, then `board.clock = rev`. On receiving a record that passes the sanitiser, `board.clock = max(board.clock, rev)`. `rev` and `created` are integers from 0 to 2^53 − 1 (`rev` from 1), the largest a Lua number holds exactly.
- **Winner:** the record with the greater `(rev, editor)`, compared lexicographically. `rev` compares as a number. `editor` compares byte by byte, not with Lua's `<`, whose order depends on the C locale. That way Lua and Python always agree.
- **Exact ties:** honest clients only produce two different records with the same `(rev, editor)` when one character edits on two installs. The tie then breaks on content: a tombstone beats a live note, then the greater `text`, `color`, `author` and `created`, in that order. MemberRecords break ties on `removed`, then `role`. BoardMeta breaks ties on the greater `name`, byte-wise. The digest can't see such a tie, so it resolves wherever both records meet (live `PUT`s or the cloud), not through anti-entropy.
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
| **Board channel** | Primary broadcast | Hidden custom channel `Cork<first 10 of boardId>`, joined with `JoinTemporaryChannel(name, secret)` and removed from every chat frame. Cap of 3 active channel-backed boards per character. Forever's reach across realms is verified in Phase 0. |
| **GUILD** | Guild boards (`board.guild = true`) | Doesn't use a channel slot. |
| **WHISPER** | Targeted replies (IDX / PUT / NEED) | Only sent to members seen via HELLO in the last 10 min, to avoid "No player named…" spam. |
| **BNet** (`BNSendGameData` / `BN_CHAT_MSG_ADDON`) | Members who are BNet friends | Larger payload per message. Its throttle behaviour is measured in Phase 0; if it's better, it's the preferred route for bulk P2P. |

### 5.2 Envelope

`{ v = 1, t = <type>, b = boardId, … }` goes through LibSerialize → LibDeflate `CompressDeflate` → `EncodeForWoWAddonChannel` → AceComm (prefix `CORK`).

ChatThrottleLib priorities: live `PUT` = `"ALERT"`, handshake = `"NORMAL"`, bulk = `"BULK"`.

The engine reads the `SendAddonMessage` result code, re-queues on a throttle result, and backs off.

### 5.3 Messages

| Type | Payload | When |
|---|---|---|
| `HELLO` | `digest, count, clock, buckets[32]` | Login, joining a board, when lockdown clears, and every 5 min ± 60 s (skipped if a HELLO for this board was seen < 2 min ago). |
| `IDX` | `{ [id] = {rev, editor} }` for mismatched buckets only | Reply to a HELLO with a differing digest. |
| `NEED` | `{ id, … }` | Requester: ids where the peer's copy is newer. |
| `PUT` | `{ Note, … }`, packed to fit about 1–2 messages | Live on local edit (broadcast); in reply to `NEED`; pushing our newer notes after an `IDX` diff. |
| `MEMBERS` | `{ MemberRecord, … }` | Piggybacked on HELLO when the member list changed. |
| `META` | `BoardMeta` | Piggybacked on HELLO when the board was renamed. The digest doesn't cover it, so it rides on every HELLO; it's under 100 bytes. |
| `CLOUD` | `cursor` | Piggybacked on HELLO. Tells peers "I'm cloud-synced to X", used by the bulk rule (§5.6). |

### 5.4 Catch-up flow

1. A logs in and broadcasts `HELLO(digest, buckets)`.
2. Each online member with a different digest schedules a reply after a random 0.5–3 s delay. The first one to reply wins. Anyone who sees another member's `IDX` aimed at A cancels their own (**responder suppression**).
3. The winner, B, sends `IDX` covering only the mismatched buckets.
4. A diffs: it sends `PUT` for notes where A is newer and `NEED` for notes where B is newer.
5. B answers `NEED` with `PUT`s. The digests now match.

### 5.5 Lockdown gate

- Before every send, check the client's outgoing-addon-message restriction (`AreOutgoingAddonChatMessagesRestricted()` in the modern API; confirm the exact name on 16001 in Phase 0), and also treat a "restricted" `SendAddonMessage` result as lockdown.
- While restricted, messages go to an outbox. Live `PUT`s coalesce by note id. A 2 s ticker retries the outbox and, once the gate opens, flushes it and sends a fresh `HELLO`.
- The gate is not driven by encounter start/end flags, so it can't get stuck closed. Local editing is never blocked.

### 5.6 Throttle budget and the bulk rule

At about 255 bytes/sec per prefix, and with other traffic sharing that budget, P2P catch-up only suits small deltas.

- **Estimate first.** After the bucket diff, the requester estimates the transfer size from the number of mismatched notes.
- **Small deltas go P2P.** If the estimate is ≤ 8 KB (about 30 s of budget), sync peer-to-peer.
- **Large deltas go to the cloud.** If the estimate is larger and this client is cloud-enabled, it syncs only the notes needed for the view the player has open (newest 20). It then shows a banner: "Board is N notes behind — cloud sync will catch up on next /reload". The companion handles the rest.
- **No cloud available.** If the client isn't cloud-enabled, full P2P sync still runs, at `"BULK"` priority, spread over time.
- Live edits always go P2P immediately; they're tiny.

---

## 6. Links and sanitisation

- Shift-click inserts a link into the focused note editor by post-hooking link insertion with `hooksecurefunc` (never pre-hooks or overrides).
- Notes render in a hyperlink-enabled frame: `OnHyperlinkEnter` shows `GameTooltip:SetHyperlink`, and `OnHyperlinkClick` calls `SetItemRef`.
- **Sanitise on receipt, identically in Lua and Python:**
  - Allowed hyperlink types: `item, quest, spell, achievement, currency, mount, battlepet, journal`.
  - Reject `|T`/`|A` textures and `|K` tokens.
  - Allow `|c…|r` colours.
  - Maximum 2,000 bytes per note.
  - A note that fails is dropped, not repaired.

  The sanitiser is a yes/no check, never a rewrite. A client that repaired a note would store different bytes under the same `(rev, editor)`, and the digest can't see that. The escape grammar is a whitelist:
  - `||`;
  - `|cAARRGGBB`, `|cnNAME:` (named colours such as `|cnIQ4:`, which modern item links may use; confirm in spike 04) and `|r`;
  - `|H<type>:<data>|h<text>|h`, where `<type>` is an allowed type and neither part contains `|`.

  Any other `|` escape fails, including `|T`, `|A`, `|K` and `|n`. Text must also be strict UTF-8, with no control characters other than `\n`.

  Records are checked as well. Note ids must be `<8 lower-case hex>-<digits>`, 18 bytes at most. Names must look like `Name-Realm`, 64 bytes at most, with no `|` or control characters. Board names (BoardMeta) must be 1–64 bytes of strict UTF-8 with at least one non-space character, and no `|` or control characters at all. `color` must be 1–8 (the UI uses 1–5), `deleted` must be a boolean, and a tombstone's text must be empty. Unknown fields are ignored, so notes from a newer client still load.

  `shared/test-vectors/sanitise.json` fixes the rules and the reason codes.
- Item and quest IDs are the ones valid on Forever. Links are built by the client, so no ID tables are needed.

---

## 7. Cloud path

### 7.1 Companion app

- **Stack:** Python 3.12 + PyInstaller single exe (Windows first; macOS later, since Forever ships on Mac).
- **Install discovery:** find the WoW root (the default Windows paths, the Mac `/Applications/World of Warcraft`, or a user-picked folder). Then pick the product subfolder that contains `Interface/AddOns/Corkboard`, preferring the Forever product. Identify the product from its flavor metadata file if present; otherwise ask once and store the choice. Handles `_classic_beta_` now and the unknown live folder later.
- **Read:** `WTF/Account/*/SavedVariables/Corkboard.lua`, parsed with a data-only Lua table parser (no `exec`). Only boards with `cloud = true` are read.
- **Triggers:** SavedVariables mtime change (logout or `/reload`), plus a pull every 10 min.
- **Sync:** `POST https://corkboard.<domain>/v1/boards/{id}/sync` with every local note whose `rev > lastPushedClock`, plus the stored cursor.
- **Write back:** regenerate `Interface/AddOns/Corkboard_Cloud/Data.lua`. This is its own tiny addon (TOC `16001`, `## Dependencies: Corkboard`) so updates to the main addon don't wipe it. The file is written atomically (temp file + rename).
- **Never** write to SavedVariables. Warn if the WoW process is running, since cloud data only appears after the next `/reload`.

### 7.2 Addon side

At `PLAYER_LOGIN`, merge `CorkboardCloudData` into `CorkboardDB` using the §4.3 rules and record `lastCloudAt` and `cloudCursor`. Merging is idempotent, so a stale `Data.lua` is harmless.

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
         text TEXT, color INT, deleted INT, seq INT, PRIMARY KEY (board_id, note_id));
members (board_id TEXT, name TEXT, role TEXT, rev INT, editor TEXT, removed INT, seq INT,
         PRIMARY KEY (board_id, name));
CREATE INDEX notes_seq ON notes(board_id, seq);
```

- **Merge:** in one transaction, upsert when the incoming record wins under §4.3 (`(rev, editor)`, then the exact-tie rule), and assign `seq = ++boards.seq` to each accepted row.
- **Limits:** 1,000 notes per board, 2,000 bytes per note, 64 KB per request, 60 requests/min per board, 20 board registrations/hour per IP.

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
    image: ghcr.io/<you>/corkboard-api:${TAG:-latest}
    restart: unless-stopped
    environment:
      CORK_DB: /data/corkboard.db
      CORK_MAX_BODY: "65536"
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
    volumes: [./Caddyfile:/etc/caddy/Caddyfile:ro, caddy-data:/data]
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
  reverse_proxy api:8000
  header { Strict-Transport-Security "max-age=31536000" -Server }
}
```

- **DNS/TLS:** an A (or CNAME) record for `corkboard.<domain>` pointing to the host's public IP. Caddy gets a Let's Encrypt certificate automatically, which needs ports 80 and 443 reachable. If the host sits behind CGNAT or you'd rather not open ports, swap Caddy's public ports for a Cloudflare Tunnel sidecar pointing at `api:8000`. Nothing else changes.
- **Exposure:** only this hostname and 443 (plus 80 for the ACME challenge). Arcane, SSH and other services stay tailnet-only.
- **Images:** GitHub Actions builds and pushes to GHCR on tag, and Arcane pulls or redeploys the stack.
- **Backups:** 7 rolling daily SQLite snapshots in the volume. Optionally Litestream to S3 or MinIO later.
- **Logging:** access logs never include the `Authorization` header. The app logs board id, route, status and latency only.

---

## 9. UI

- **Board list:** name, members, who's online (from recent HELLOs), and a sync badge such as "P2P: Bob 3m ago · Cloud: 2h ago", "Queued (restricted)", or "N behind: /reload after cloud sync".
- **Board view:** sticky-card grid (colour, author, relative time, live links).
- **Editor:** multiline EditBox, shift-click links, character counter, colour picker.
- **Share:** "Copy invite" produces `CORK1:<base64(boardId|secret|ownerName)>`. "Join" takes a pasted string.
- **Slash commands:** `/cork`, `/cork join <invite>`, `/cork sync`, `/cork debug`.
- Works with Forever's modern and Classic visual presets (no reliance on retail-only art atlases; verify in Phase 1).

---

## 10. Trust model and risks

- **Membership = holding the secret.** Revoking someone means rotating the secret (new channel password and cloud credential), then re-sharing it with the remaining members.
- **Transport identity is server-verified; relayed authorship is not.** A malicious member could forge `author`. This is accepted for v1.
- **Public API surface:** auth on every board route, strict size and rate limits, the same sanitiser as the addon, and no admin endpoints.
- **Platform risk:** Forever is pre-launch. API names, restrictions, the throttle and the install layout can all change before and after 2026-11-04. Phase 0 re-runs at launch.

---

## 11. Testing

- The merge, digest and sanitiser code is pure Lua 5.1 (no WoW API), tested with `busted`.
- Shared JSON test vectors run in both the Lua tests and pytest.
- Hypothesis property tests: random edits, deletes, and reordered, duplicated or dropped deliveries across 3–5 simulated nodes plus a simulated server must converge to the same digest.
- A throttle simulator (1 msg/s per prefix, burst of 10) validates the bulk-rule thresholds before in-game testing.
- The `/cork debug` panel shows outbox depth, throttle stalls, gate state, bucket diffs, and last HELLO per member.

---

## 12. Phases and acceptance criteria

**Phase 0: Forever spikes (gate: every item answered in writing on the 1.60 beta, and re-checked at launch)**
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

**Phase 2: Live P2P**
- [ ] Invites round-trip. The hidden channel never shows in any chat frame.
- [ ] With 2 clients online, an edit appears on the other client within 5 s.
- [ ] Non-member traffic is ignored, and secret payloads are dropped without errors.

**Phase 3: Anti-entropy**
- [ ] With A offline, B makes 20 creates, 5 edits and 3 deletes. After A logs in, the digests match within 60 s via P2P, and the debug panel shows only mismatched buckets were exchanged.
- [ ] Deleted notes never reappear, including when a stale third client logs in.
- [ ] Concurrent edits to the same note converge to the same winner on 3 clients.
- [ ] With 5 members online, a HELLO triggers exactly one IDX in ≥ 90% of trials.

**Phase 4: Hardening**
- [ ] Edits during an encounter (and while dead) are queued and delivered within 10 s of the gate opening, with no Lua errors or `ADDON_ACTION_FORBIDDEN`.
- [ ] No message is ever lost to throttling (verified with result-code logging over a 500-note sync).
- [ ] The bulk rule triggers above 8 KB, and the banner shows.
- [ ] The sanitiser fuzz corpus is rejected identically in Lua and Python.

**Phase 5: Cloud + hosting**
- [ ] The stack deploys from Arcane. `https://corkboard.<domain>/v1/health` returns 200 over valid TLS from outside the tailnet, and the Arcane dashboard is unreachable from the internet.
- [ ] B edits and logs out. With nobody else online, A's companion syncs, then A `/reload`s and sees B's edits.
- [ ] A 500-note board catches up entirely via the cloud, with no P2P bulk traffic.
- [ ] Wrong secret gives 401, a rotated secret invalidates the old one, and rate limits return 429.
- [ ] The companion never writes SavedVariables, and `Data.lua` writes are atomic.
- [ ] A backup restore drill: restore yesterday's snapshot into a fresh stack, and the digests match.

**Phase 6: Distribution**
- [ ] `Corkboard` + `Corkboard_Cloud` packages (interface 16001) on CurseForge and Wago, once they list the Forever flavour.
- [ ] Signed companion installer with a first-run wizard (finds the Forever install, sets the API URL).

---

## 13. Dependencies

- **Addon:** Ace3 (AceAddon, AceDB, AceEvent, AceComm, AceTimer, AceConsole, with ChatThrottleLib), LibSerialize, LibDeflate, LibDataBroker, LibDBIcon. All must be current builds that load on modern-API clients.
- **Companion/API:** Python 3.12, FastAPI, SQLite, a Lua-table data parser, Hypothesis, PyInstaller.
- **Infra:** Arcane, Caddy 2, GHCR, GitHub Actions.

## 14. Open questions

1. Does the Arcane host already run a reverse proxy on 80/443? If so, drop the `caddy` service and add a route there instead.
2. Public IP with port forwarding, or a Cloudflare Tunnel (CGNAT, or to avoid opening ports)?
3. Delete permissions: can any member delete any note, or only the author and the owner? This is enforceable at the API and UI level only.
4. Guild boards: auto-join for the whole guild, or invite-only?
