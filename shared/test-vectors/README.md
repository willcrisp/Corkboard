# Shared test vectors

JSON fixtures that pin down the merge core (docs/design.md §4.3, §4.4, §6). The Lua suite (`addon/spec/`) runs every case. The Python ports in `companion/` and `api/` must run the same cases and pass them unchanged. A case that one side can't pass is a bug in that side, not in the vector.

Expected Adler-32 and digest values were computed with Python's `zlib.adler32`, independently of the Lua code. Merge and sanitiser expectations are written out by hand from the spec.

## Conventions

- **Strings** are UTF-8. A field ending in `_hex` holds raw bytes instead, for input that isn't valid UTF-8. Python should decode it with `bytes.fromhex(h).decode("utf-8", "surrogateescape")`, so an invalid byte becomes a lone surrogate that fails the same checks.
- **Text inputs** are built as `input` (or the bytes of `input_hex`), repeated `repeat` times (default 1), then followed by `append` (default empty).
- **Integers:** a JSON number with no fractional part counts as an integer, so `1790000456.0` is valid wherever `1790000456` is. Booleans are never integers (watch for this in Python, where `True` is an `int`).
- **Integer range:** revs and timestamps must be at most 2^53 − 1 (9007199254740991), the largest integer a Lua number holds exactly.
- **Byte order:** strings compare byte by byte, never with a locale. For valid UTF-8 that's the same as Python's code-point order.
- **No arrays where an object is expected:** Lua can't tell an empty array from an empty object, so no case relies on that difference.

## Files

### `adler32.json`

`cases[]`: `{ input | input_hex, repeat?, adler32 }`. This is Adler-32 exactly as in zlib (and `LibDeflate:Adler32`).

### `sanitise.json`

- `text[]`: `{ name, input | input_hex, repeat?, append?, ok, reason? }` for `Sanitise.text`. When `ok` is false, `reason` is the first check that failed, in this order: `text` (not a string), `too_long`, `utf8`, `control`, then a left-to-right scan of `|` escapes that gives `escape`, `link` or `link_type`.
- `name[]`: `{ name, input | input_hex, append?, ok }` for character names (`Name-Realm`).
- `note` and `member`: `{ base, cases[] }`. Each case's record is `input` if present. Otherwise it's `base` with `patch` merged over it and the fields in `remove` deleted. When `ok` is true, the sanitiser returns a copy equal to `output` (default: the record itself), with unknown fields dropped. When `ok` is false it returns `reason`. Fields are checked in this order:
  - notes: `id`, `author`, `created`, `rev`, `editor`, `color`, `deleted`, then the text reasons, then `tombstone_text`;
  - members: `name`, `role`, `rev`, `editor`, `removed`.

  Anything that isn't an object gives `type`.

### `merge.json`

`notes[]` and `members[]`: `{ name, board, apply[], results[], expect }`.

1. Start from `board`: a `clock` and a list of records, which are stored as they are.
2. Apply each record in `apply` in order.
3. `results[i]` is the outcome of `apply[i]`: `stored`, `stale` (valid, but not newer than what the board holds), or the sanitiser's reason for dropping it.
4. At the end, the board must equal `expect`: its `clock` and its records, with nothing extra. Only valid records move the clock.

The final board must be the same for every order of `apply`, and when `apply` runs twice.

### `digest.json`

- `bucket[]`: `{ id, bucket }`, where the bucket is `Adler32(id) % 32`.
- `line[]`: `{ note, line }`, the digest line `id=rev;editor\n`, with `rev` in plain decimal.
- `boards[]`: `{ name, notes[], count, buckets[32], digest }`. `buckets[0]` is bucket 0. Each bucket hash is the Adler-32 of that bucket's lines, sorted byte-wise and joined. The digest is the Adler-32 of the 32 hashes, each written as 4 big-endian bytes. `count` includes tombstones. The "lines sort byte-wise, not by id" board catches an implementation that sorts by id instead: `a1b2c3d4-7` sorts before `a1b2c3d4-700`, but its line sorts after, because `=` is greater than `0`.
