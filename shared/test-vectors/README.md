# Shared test vectors

JSON fixtures that pin down the merge core (docs/design.md §4.3, §4.4, §6). The Lua suite (`addon/spec/`) runs every case. The Python port (`shared/python/corkcore`, used by `companion/` and `api/`) and the JavaScript port (`web/public/js/core/`, tested by `web/test/vectors.test.mjs`) must run the same cases and pass them unchanged. JavaScript decodes `input_hex` the way Python does, with each invalid byte kept as U+DC00 + byte. A case that one side can't pass is a bug in that side, not in the vector.

Expected FNV-1a and digest values were computed with a short Python reference implementation, independently of the Lua code, and checked against the published FNV test values. Merge and sanitiser expectations are written out by hand from the spec.

## Conventions

- **Strings** are UTF-8. A field ending in `_hex` holds raw bytes instead, for input that isn't valid UTF-8. Python should decode it with `bytes.fromhex(h).decode("utf-8", "surrogateescape")`, so an invalid byte becomes a lone surrogate that fails the same checks.
- **Text inputs** are built as `input` (or the bytes of `input_hex`), repeated `repeat` times (default 1), then followed by `append` (default empty).
- **Integers:** a JSON number with no fractional part counts as an integer, so `1790000456.0` is valid wherever `1790000456` is. Booleans are never integers (watch for this in Python, where `True` is an `int`).
- **Integer range:** revs and timestamps must be at most 2^53 − 1 (9007199254740991), the largest integer a Lua number holds exactly.
- **Byte order:** strings compare byte by byte, never with a locale. For valid UTF-8 that's the same as Python's code-point order.
- **No arrays where an object is expected:** Lua can't tell an empty array from an empty object, so no case relies on that difference.

## Files

### `fnv1a32.json`

`cases[]`: `{ input | input_hex, repeat?, fnv1a32 }`. This is 32-bit FNV-1a: start from 2166136261, and for each byte xor it in, then multiply by 16777619 modulo 2^32. In Python: `h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF`.

### `sanitise.json`

- `text[]`: `{ name, input | input_hex, repeat?, append?, ok, reason? }` for `Sanitise.text`. When `ok` is false, `reason` is the first check that failed, in this order: `text` (not a string), `too_long`, `utf8`, `control`, then a left-to-right scan of `|` escapes that gives `escape`, `link` or `link_type`.
- `name[]`: `{ name, input | input_hex, append?, ok }` for character names (`Name-Realm`).
- `board_name[]`: `{ name, input | input_hex, repeat?, append?, ok }` for board names: 1–64 bytes of strict UTF-8 with at least one non-space, and no control characters or `|` at all (not even `||`).
- `note`, `member` and `meta`: `{ base, cases[] }`. Each case's record is `input` if present. Otherwise it's `base` with `patch` merged over it and the fields in `remove` deleted. When `ok` is true, the sanitiser returns a copy equal to `output` (default: the record itself), with unknown fields dropped. When `ok` is false it returns `reason`. Fields are checked in this order:
  - notes: `id`, `author`, `created`, `rev`, `editor`, `color`, `deleted`, `kind` (absent, `"gear"` for a gear-feed entry, `"recipes"` for a recipe list or `"quests"` for a quest log; kept in the output only when present), then the text reasons, then `tombstone_text`;
  - members: `name`, `role`, `rev`, `editor`, `removed`;
  - meta (the board's name record): `name`, `rev`, `editor`.

  Anything that isn't an object gives `type`.

### `merge.json`

`notes[]`, `members[]` and `meta[]`: `{ name, board, apply[], results[], expect }`.

1. Start from `board`: a `clock` and a list of records, which are stored as they are. A board holds a single meta record, so in `meta[]` cases `board.meta` and `expect.meta` are one record (absent when the board has none) instead of a list.
2. Apply each record in `apply` in order.
3. `results[i]` is the outcome of `apply[i]`: `stored`, `stale` (valid, but not newer than what the board holds), or the sanitiser's reason for dropping it.
4. At the end, the board must equal `expect`: its `clock` and its records, with nothing extra. Only valid records move the clock.

The final board must be the same for every order of `apply`, and when `apply` runs twice.

On an exact `(rev, editor)` tie between notes, a tombstone wins, then the greater `kind` (a missing kind counts as the empty string), `text`, `color`, `author` and `created`.

Meta records win on `(rev, editor)` like the others. On an exact tie the greater `name`, compared byte-wise, wins.

### `digest.json`

- `bucket[]`: `{ id, bucket }`, where the bucket is `FNV1a32(id) % 32`.
- `line[]`: `{ note, line }`, the digest line `id=rev;editor\n`, with `rev` in plain decimal.
- `boards[]`: `{ name, notes[], count, buckets[32], digest }`. `buckets[0]` is bucket 0. Each bucket hash is the FNV-1a of that bucket's lines, sorted byte-wise and joined, so an empty bucket hashes to 2166136261. The digest is the FNV-1a of the 32 hashes, each written as 4 big-endian bytes. `count` includes tombstones. The "lines sort byte-wise, not by id" board catches an implementation that sorts by id instead: `a1b2c3d4-7` sorts before `a1b2c3d4-722` (chosen to share its bucket), but its line sorts after, because `=` is greater than `2`. The two "revs 81 apart" boards hold the same note at revs whose digest lines collide under Adler-32; their digests must differ.

### `invite.json`

Invite strings (§9): `CORK1:` then standard base64 (with `=` padding) of `boardId|secret|ownerName`.

- `encode[]`: `{ name, board: { id, secret, owner }, invite }`. Encoding always writes the padding and an upper-case `CORK1:`.
- `decode[]`: `{ name, input, ok, output?, reason? }`. Decoding ignores surrounding whitespace, the case of `CORK`, and missing padding. It fails with `invite` when the text isn't a Corkboard invite, `invite_version` for any version other than 1, and `invite_corrupt` when the base64 or its fields are bad. A valid id is 16 lower-case base36 characters, a secret is 16–64 ASCII letters and digits, and the owner must pass the character-name check from `sanitise.json`.

### `sanitise_fuzz.json`

A seeded corpus of hostile strings (§12 Phase 4: "the sanitiser fuzz corpus is rejected identically in Lua and Python"), generated by `tools/gen_sanitise_fuzz.py` from escape fragments, UTF-8 edge cases, control characters and invalid bytes. The expected results come from the Python sanitiser in `shared/python/corkcore`, and the Lua suite (`addon/spec/sanitise_fuzz_spec.lua`) must agree on every case. Regenerate it after any change to either sanitiser, and never edit it by hand.

- `text[]`: `{ input_hex, ok, reason? }` for `Sanitise.text`.
- `name[]` and `board_name[]`: `{ input_hex, ok }` for the name checks.
