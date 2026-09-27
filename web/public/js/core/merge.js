// Merge rules (docs/design.md §4.3, Core/Merge.lua, corkcore/merge.py):
// last-writer-wins on (rev, editor), tombstones for deletes, and the
// HLC-lite board clock.
//
// A board is an object with `clock`, `notes` (id -> note), `members`
// (name -> record) and `meta` (one record or null). Missing fields are
// created on first write.

import * as sanitise from "./sanitise.js";
import { compare as compareBytes } from "./util.js";

function cmp(x, y) {
  if (x === y) return 0;
  return x < y ? -1 : 1;
}

export function compareVersion(a, b) {
  return cmp(a.rev, b.rev) || compareBytes(a.editor, b.editor);
}

// Total order on two versions of one note: (rev, editor), then a tombstone
// wins the tie, then the greater kind (missing counts as ""), text, color,
// author and created.
export function compareNote(a, b) {
  return compareVersion(a, b)
    || cmp(Number(Boolean(a.deleted)), Number(Boolean(b.deleted)))
    || compareBytes(a.kind || "", b.kind || "")
    || compareBytes(a.text, b.text)
    || cmp(a.color, b.color)
    || compareBytes(a.author, b.author)
    || cmp(a.created, b.created);
}

export function compareMember(a, b) {
  return compareVersion(a, b)
    || cmp(Number(Boolean(a.removed)), Number(Boolean(b.removed)))
    || compareBytes(a.role, b.role);
}

export function compareMeta(a, b) {
  return compareVersion(a, b) || compareBytes(a.name, b.name);
}

// Clock ------------------------------------------------------------------------

export function observe(board, rev) {
  if (rev > (board.clock || 0)) board.clock = rev;
}

export function nextRev(board, now) {
  const after = (board.clock || 0) + 1;
  return now > after ? now : after;
}

// Received records ----------------------------------------------------------------

function records(board, field) {
  if (!board[field]) board[field] = {};
  return board[field];
}

function store(board, field, key, clean, compare) {
  observe(board, clean.rev);
  const held = records(board, field);
  const current = Object.prototype.hasOwnProperty.call(held, key) ? held[key] : undefined;
  if (current !== undefined && compare(clean, current) <= 0) return [false, "stale"];
  held[key] = clean;
  return [true, null];
}

// Merges one received note: [true, null] if stored, else [false, reason]:
// "stale" or the sanitiser's reason.
export function applyNote(board, note) {
  const [clean, reason] = sanitise.note(note);
  if (!clean) return [false, reason];
  return store(board, "notes", clean.id, clean, compareNote);
}

export function applyMember(board, member) {
  const [clean, reason] = sanitise.member(member);
  if (!clean) return [false, reason];
  return store(board, "members", clean.name, clean, compareMember);
}

export function applyMeta(board, meta) {
  const [clean, reason] = sanitise.meta(meta);
  if (!clean) return [false, reason];
  observe(board, clean.rev);
  const current = board.meta;
  if (current && compareMeta(clean, current) <= 0) return [false, "stale"];
  board.meta = clean;
  return [true, null];
}

function applyAll(board, list, apply, key) {
  const stored = [];
  const dropped = [];
  for (const record of list) {
    const [ok, reason] = apply(board, record);
    if (ok) stored.push(record[key]);
    else if (reason !== "stale") dropped.push(reason);
  }
  return [stored, dropped];
}

export function applyNotes(board, notes) {
  return applyAll(board, notes, applyNote, "id");
}

export function applyMembers(board, members) {
  return applyAll(board, members, applyMember, "name");
}

// Local changes ------------------------------------------------------------------

function commit(board, field, key, record, check) {
  const [clean, reason] = check(record);
  if (!clean) return [null, reason];
  observe(board, clean.rev);
  records(board, field)[clean[key]] = clean;
  return [clean, null];
}

export function createNote(board, fields, now) {
  if (board.notes && Object.prototype.hasOwnProperty.call(board.notes, fields.id)) return [null, "exists"];
  return commit(board, "notes", "id", {
    id: fields.id, author: fields.author, created: now, rev: nextRev(board, now), editor: fields.author,
    text: fields.text, color: fields.color ?? 1, deleted: false, kind: fields.kind,
  }, sanitise.note);
}

function current(board, noteId) {
  const note = board.notes && Object.prototype.hasOwnProperty.call(board.notes, noteId) ? board.notes[noteId] : null;
  if (!note) return [null, "missing"];
  if (note.deleted) return [null, "deleted"];
  return [note, null];
}

export function editNote(board, noteId, changes, editor, now) {
  const [note, reason] = current(board, noteId);
  if (!note) return [null, reason];
  return commit(board, "notes", "id", {
    id: noteId, author: note.author, created: note.created, rev: nextRev(board, now), editor,
    text: changes.text ?? note.text, color: changes.color ?? note.color, deleted: false, kind: note.kind,
  }, sanitise.note);
}

export function deleteNote(board, noteId, editor, now) {
  const [note, reason] = current(board, noteId);
  if (!note) return [null, reason];
  return commit(board, "notes", "id", {
    id: noteId, author: note.author, created: note.created, rev: nextRev(board, now), editor,
    text: "", color: note.color, deleted: true, kind: note.kind,
  }, sanitise.note);
}

export function setMember(board, name, role, removed, editor, now) {
  return commit(board, "members", "name", {
    name, role, rev: nextRev(board, now), editor, removed,
  }, sanitise.member);
}

export function setMeta(board, name, editor, now) {
  const [clean, reason] = sanitise.meta({ name, rev: nextRev(board, now), editor });
  if (!clean) return [null, reason];
  observe(board, clean.rev);
  board.meta = clean;
  return [clean, null];
}
