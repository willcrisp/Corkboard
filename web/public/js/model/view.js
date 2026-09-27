// Labels, ages, search and identity for the web app: the parts of the addon's
// Core/View.lua and Core/Commands.lua the web window needs, so both read the
// same ("2h", "Will · edited by Bob", "3 notes").

import * as sanitise from "../core/sanitise.js";
import { byteLen, compare, formatInt, hex8, isUtf8 } from "../core/util.js";
import { plain } from "./text.js";

// Note tags, by note colour 1-5 (docs/ui-style.md).
export const TAGS = [
  { name: "Amber", color: "#9a7a3c" },
  { name: "Blue", color: "#4f6f92" },
  { name: "Green", color: "#5d7d4c" },
  { name: "Rose", color: "#8f5563" },
  { name: "Violet", color: "#6d5c8f" },
];

// Colours 6-8 pass the sanitiser but have no tag yet: they show as the first.
export function tag(color) {
  return TAGS[color - 1] || TAGS[0];
}

export function plural(n, word) {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

// "now", "5m", "2h", "3d".
export function shortAge(seconds) {
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

// "just now", "5m ago".
export function age(seconds) {
  return seconds < 60 ? "just now" : `${shortAge(seconds)} ago`;
}

// "Will" from "Will-Realm". The web app has no realm of its own, so the
// realm always goes (the full name is on hover).
export function shortName(name) {
  const m = /^([^-]+)-(.+)$/.exec(name || "");
  return m ? m[1] : name;
}

// "Will" or "Kaelthra · edited by Mira".
export function byline(note) {
  const author = shortName(note.author);
  if (note.editor === note.author) return author;
  return `${author} · edited by ${shortName(note.editor)}`;
}

// "Molten Core prep · created by Will 2h ago · edited by Bob 14m ago".
export function editorHeader(boardName, note, now) {
  if (!note) return `${boardName} · new note`;
  const parts = [boardName, `created by ${shortName(note.author)} ${age(now - note.created)}`];
  if (note.rev !== note.created || note.editor !== note.author) {
    parts.push(`edited by ${shortName(note.editor)} ${age(now - note.rev)}`);
  }
  return parts.join(" · ");
}

export function boardName(board) {
  return board.meta ? board.meta.name : board.id;
}

// Search: every word of the query must appear (ASCII case folded) in the
// note's plain text or its author's or editor's name (View.matches).
export function matches(haystack, query) {
  const text = haystack.replace(/[A-Z]/g, (c) => c.toLowerCase());
  for (const word of (query || "").replace(/[A-Z]/g, (c) => c.toLowerCase()).split(/[ \t\n\v\f\r]+/)) {
    if (word && !text.includes(word)) return false;
  }
  return true;
}

export function noteMatches(note, query) {
  return matches(`${plain(note.text)}\n${note.author}\n${note.editor}`, query);
}

export function count(total, shown) {
  return total === shown ? plural(total, "note") : `${shown} of ${total} notes`;
}

// The byte counter under an editor.
export function counter(size) {
  return { label: `${size} / ${sanitise.MAX_TEXT}`, over: size > sanitise.MAX_TEXT };
}

// "45:1790004412:9f3a01c2": count, clock and digest, as /cork debug shows them.
export function digestLabel(count, clock, digest) {
  return `${count}:${formatInt(clock || 0)}:${hex8(digest || 0)}`;
}

// Sentences for reason codes (Commands.explain), plus the web app's own.
const REASONS = {
  author: "Your name couldn't be used. Change it and try again.",
  editor: "Your name couldn't be used. Change it and try again.",
  name: `Board names are 1-${sanitise.MAX_BOARD_NAME} bytes, with no | or line breaks.`,
  too_long: `Notes are limited to ${sanitise.MAX_TEXT} bytes.`,
  utf8: "That text isn't valid UTF-8.",
  control: "Notes can't contain control characters other than line breaks.",
  escape: "Notes can hold links and colours, but not textures, icons or other escape codes.",
  link: "That link is malformed.",
  link_type: "That kind of link can't go on a board.",
  id_space: "You've run out of note ids on this board.",
  deleted: "That note has been deleted.",
  missing: "That board or note no longer exists.",
  invite: "That isn't a Corkboard invite. It starts with CORK1:",
  invite_version: "That invite is from a newer version of Corkboard.",
  invite_corrupt: "That invite is damaged. Copy the whole string again.",
  player_name: "Character names are 1-64 bytes, with no ; or | in them.",
  verdict: "Pick Avoid or Good player.",
  web_name: "Names are 1-64 bytes with a letter or digit, and no | or line breaks. Add -Realm to match a character.",
  empty: "Write something first.",
};

export function explain(reason) {
  return REASONS[reason] || `That didn't work (${reason}).`;
}

// Identity ---------------------------------------------------------------------------

// The name the web app writes as a note's author and editor. The game's
// records need "Name-Realm" (§6), so a name typed without a realm gets
// "-Web", which also tells members in game where the note came from. A name
// typed with a realm is used as it is, so a player can post as their
// character. Returns [name] or [null, "web_name"].
export function webName(input) {
  if (typeof input !== "string") return [null, "web_name"];
  let name = input.replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, "").replace(/[ \t\n\v\f\r]+/g, " ");
  if (!name || !/[0-9A-Za-z\u0080-￿]/.test(name.split("-")[0])) return [null, "web_name"];
  if (!/^[^-]+-./.test(name)) name = `${name.replace(/-+$/, "")}-Web`;
  if (!sanitise.name(name) || !isUtf8(name) || byteLen(name) > sanitise.MAX_NAME) return [null, "web_name"];
  return [name, null];
}

// A new device's note-id prefix: 8 random hex digits. The game derives its
// prefix from the character's GUID (§4.2); the web app has none, so each
// device gets its own and never shares a counter with another install.
export function newPrefix(random = Math.random) {
  return hex8(Math.floor(random() * 0x100000000));
}

export const MAX_COUNTER = 999999999;

// The next note id for this prefix on a board (Store.nextNoteId): one more
// than the highest counter of any note with the prefix, at least 4 digits.
export function nextNoteId(board, prefix) {
  let highest = 0;
  for (const id of Object.keys(board.notes || {})) {
    if (id.startsWith(`${prefix}-`)) {
      const n = Number(id.slice(9));
      if (n > highest) highest = n;
    }
  }
  if (highest >= MAX_COUNTER) return [null, "id_space"];
  return [`${prefix}-${String(highest + 1).padStart(4, "0")}`, null];
}

export function byName(a, b) {
  return compare(shortName(a).toLowerCase(), shortName(b).toLowerCase()) || compare(a, b);
}
