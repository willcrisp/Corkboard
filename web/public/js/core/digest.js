// Bucketed board digests (docs/design.md §4.4, Core/Digest.lua,
// corkcore/digest.py). The web app doesn't exchange digests, but it shows
// one on the Members tab so a member can compare it with /cork debug.

import { compareByteArrays, fnv1a32, formatInt, toBytes, uint32be } from "./util.js";

export const BUCKETS = 32;

export function bucket(noteId) {
  return fnv1a32(noteId) % BUCKETS;
}

export function line(note) {
  return `${note.id}=${formatInt(note.rev)};${note.editor}\n`;
}

export function combine(buckets) {
  const bytes = [];
  for (const h of buckets) bytes.push(...uint32be(h));
  return fnv1a32(bytes);
}

// {digest, buckets, count}; count includes tombstones.
export function compute(notes) {
  const list = Array.isArray(notes) ? notes : Object.values(notes || {});
  const lines = Array.from({ length: BUCKETS }, () => []);
  for (const note of list) lines[bucket(note.id)].push(toBytes(line(note)));
  const hashes = lines.map((group) => {
    group.sort(compareByteArrays);
    return fnv1a32(group.flat());
  });
  return { digest: combine(hashes), buckets: hashes, count: list.length };
}
