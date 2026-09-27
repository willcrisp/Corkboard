// The sanitiser (docs/design.md §6, Core/Sanitise.lua, corkcore/sanitise.py):
// a yes/no check, never a repair. shared/test-vectors/sanitise.json pins the
// behaviour and the reasons. Results are [value, reason] pairs, like the
// Python tuples.

import { INT_MAX, byteLen, isInteger, isUtf8 } from "./util.js";

export const MAX_TEXT = 2000;
export const MAX_NAME = 64;
export const MAX_BOARD_NAME = 64;
export const MAX_ID = 18;
export const COLOR_MAX = 8;

export const LINK_TYPES = new Set([
  "item", "quest", "spell", "achievement", "currency", "mount", "battlepet", "journal",
  "enchant", "trade", // a profession recipe and a whole profession (§9.2)
]);
// Note kinds (§4.2): none for an ordinary note, "gear" (§9.1), "recipes"
// (§9.2), "quests" (§9.3) and "player" (§9.4).
export const KINDS = new Set(["gear", "recipes", "quests", "player"]);

const CONTROL = /[\x00-\x1f\x7f]/;
const TEXT_CONTROL = /[\x00-\x09\x0b-\x1f\x7f]/;
const HEX8 = /[0-9A-Fa-f]{8}/y;
const NAMED_COLOUR = /n[0-9A-Za-z_]+:/y;
const LINK_TYPE = /([^:|]*):/y;
const LINK_REST = /[^|]*\|h[^|]*\|h/y;
const NOTE_ID = /^[0-9a-f]{8}-[0-9]+$/;
// Lua's %S in the C locale: anything but space, \t, \n, \v, \f and \r.
const NON_SPACE = /[^ \t\n\v\f\r]/;
const NAME = /^[^-]+-[\s\S]/;

function at(re, s, pos) {
  re.lastIndex = pos;
  return re.exec(s);
}

function checkEscapes(s) {
  let pos = 0;
  for (;;) {
    const p = s.indexOf("|", pos);
    if (p < 0) return [true, null];
    const c = s.charAt(p + 1);
    if (c === "|" || c === "r") {
      pos = p + 2;
    } else if (c === "c") {
      if (at(HEX8, s, p + 2)) {
        pos = p + 10;
      } else {
        const m = at(NAMED_COLOUR, s, p + 2);
        if (!m) return [false, "escape"];
        pos = NAMED_COLOUR.lastIndex;
      }
    } else if (c === "H") {
      const m = at(LINK_TYPE, s, p + 2);
      if (!m) return [false, "link"];
      if (!LINK_TYPES.has(m[1])) return [false, "link_type"];
      const end = LINK_TYPE.lastIndex;
      if (!at(LINK_REST, s, end)) return [false, "link"];
      pos = LINK_REST.lastIndex;
    } else {
      return [false, "escape"];
    }
  }
}

// Note text: [true, null] or [false, reason]. Reasons in order: text,
// too_long, utf8, control, then escape, link or link_type left to right.
export function text(s) {
  if (typeof s !== "string") return [false, "text"];
  if (byteLen(s) > MAX_TEXT) return [false, "too_long"];
  if (!isUtf8(s)) return [false, "utf8"];
  if (TEXT_CONTROL.test(s)) return [false, "control"];
  return checkEscapes(s);
}

// A character name, "Name-Realm".
export function name(s) {
  return typeof s === "string" && byteLen(s) <= MAX_NAME && NAME.test(s) && !s.includes("|")
    && !CONTROL.test(s) && isUtf8(s);
}

export function boardName(s) {
  return typeof s === "string" && byteLen(s) <= MAX_BOARD_NAME && NON_SPACE.test(s) && !s.includes("|")
    && !CONTROL.test(s) && isUtf8(s);
}

export function noteId(s) {
  return typeof s === "string" && byteLen(s) <= MAX_ID && NOTE_ID.test(s);
}

function isObject(t) {
  return t !== null && typeof t === "object" && !Array.isArray(t);
}

// A clean copy with only the known fields, or [null, reason].
export function note(t) {
  if (!isObject(t)) return [null, "type"];
  if (!noteId(t.id)) return [null, "id"];
  if (!name(t.author)) return [null, "author"];
  if (!isInteger(t.created, 0, INT_MAX)) return [null, "created"];
  if (!isInteger(t.rev, 1, INT_MAX)) return [null, "rev"];
  if (!name(t.editor)) return [null, "editor"];
  if (!isInteger(t.color, 1, COLOR_MAX)) return [null, "color"];
  if (typeof t.deleted !== "boolean") return [null, "deleted"];
  const kind = t.kind;
  if (kind !== undefined && kind !== null && !(typeof kind === "string" && KINDS.has(kind))) return [null, "kind"];
  const [ok, reason] = text(t.text);
  if (!ok) return [null, reason];
  if (t.deleted && t.text !== "") return [null, "tombstone_text"];
  const clean = {
    id: t.id,
    author: t.author,
    created: t.created,
    rev: t.rev,
    editor: t.editor,
    text: t.text,
    color: t.color,
    deleted: t.deleted,
  };
  if (kind !== undefined && kind !== null) clean.kind = kind;
  return [clean, null];
}

export function member(t) {
  if (!isObject(t)) return [null, "type"];
  if (!name(t.name)) return [null, "name"];
  if (t.role !== "owner" && t.role !== "member") return [null, "role"];
  if (!isInteger(t.rev, 1, INT_MAX)) return [null, "rev"];
  if (!name(t.editor)) return [null, "editor"];
  if (typeof t.removed !== "boolean") return [null, "removed"];
  return [{ name: t.name, role: t.role, rev: t.rev, editor: t.editor, removed: t.removed }, null];
}

export function meta(t) {
  if (!isObject(t)) return [null, "type"];
  if (!boardName(t.name)) return [null, "name"];
  if (!isInteger(t.rev, 1, INT_MAX)) return [null, "rev"];
  if (!name(t.editor)) return [null, "editor"];
  return [{ name: t.name, rev: t.rev, editor: t.editor }, null];
}
