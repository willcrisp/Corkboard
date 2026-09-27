// The note kinds the game writes, read (and for player notes, written) the
// same way the addon does: player notes (Core/Players.lua, §9.4), recipe
// lists (Core/Recipes.lua, §9.2), quest logs (Store.decodeQuests, §9.3) and
// the gear feed (Store.gear, §9.1).

import * as sanitise from "../core/sanitise.js";
import { byteLen, compare, isInteger, isUtf8 } from "../core/util.js";
import { compareNote, compareVersion } from "../core/merge.js";

// Player notes --------------------------------------------------------------------

export const PLAYER_KIND = "player";
export const PLAYER_MAX_NAME = 64;
export const VERDICTS = new Set(["avoid", "good"]);
export const VERDICT_LABELS = { avoid: "Avoid", good: "Good player" };

const PLAYER_HEADER = /^P1;([a-z]+);([^;\n]+)$/;
// Lua's %c in the C locale.
const LUA_CONTROL = /[\x00-\x1f\x7f]/;

function luaTrim(s) {
  return s.replace(/^[ \t\n\v\f\r]+/, "").replace(/[ \t\n\v\f\r]+$/, "");
}

// What entries are matched on: the first word of the name, before any
// surname or realm, ASCII lower-cased (Players.key).
export function playerKey(name) {
  if (typeof name !== "string") return null;
  const m = /^[ \t\n\v\f\r]*([^ \t\n\v\f\r-]+)/.exec(name);
  if (!m || !/[0-9A-Za-z\u0080-￿]/.test(m[1])) return null;
  return m[1].replace(/[A-Z]/g, (c) => c.toLowerCase());
}

// A character name as typed, tidied (Players.cleanName): [name] or
// [null, "player_name"].
export function cleanPlayerName(name) {
  if (typeof name !== "string") return [null, "player_name"];
  name = luaTrim(name).replace(/[ \t\n\v\f\r]+/g, " ");
  const size = byteLen(name);
  if (size < 1 || size > PLAYER_MAX_NAME || /[;|]/.test(name) || LUA_CONTROL.test(name) || !isUtf8(name)
    || !playerKey(name)) {
    return [null, "player_name"];
  }
  return [name, null];
}

// The note text for an entry (Players.encode): [text] or [null, reason].
export function encodePlayer(name, verdict, reason) {
  const [clean, why] = cleanPlayerName(name);
  if (!clean) return [null, why];
  if (!VERDICTS.has(verdict)) return [null, "verdict"];
  reason = luaTrim(typeof reason === "string" ? reason : "");
  let text = `P1;${verdict};${clean}`;
  if (reason !== "") text += `\n${reason}`;
  const [ok, bad] = sanitise.text(text);
  if (!ok) return [null, bad];
  return [text, null];
}

// Reads an entry's text: { name, verdict, reason, key } or null.
export function decodePlayer(text) {
  if (typeof text !== "string") return null;
  const newline = text.indexOf("\n");
  const header = newline >= 0 ? text.slice(0, newline) : text;
  const m = PLAYER_HEADER.exec(header);
  if (!m || !VERDICTS.has(m[1]) || cleanPlayerName(m[2])[0] !== m[2]) return null;
  return { name: m[2], verdict: m[1], reason: newline >= 0 ? text.slice(newline + 1) : "", key: playerKey(m[2]) };
}

const asciiLower = (s) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());

// The board's live entries, by name (case folded), then newest first.
export function playerEntries(board) {
  const list = [];
  for (const note of Object.values(board.notes || {})) {
    if (note.deleted || note.kind !== PLAYER_KIND) continue;
    const entry = decodePlayer(note.text);
    if (entry) list.push({ ...entry, note });
  }
  list.sort((a, b) => compare(asciiLower(a.name), asciiLower(b.name)) || -compareVersion(a.note, b.note)
    || compare(a.note.id, b.note.id));
  return list;
}

// Recipe lists ----------------------------------------------------------------------

export const RECIPES_KIND = "recipes";
const RECIPE_MAX_ID = 2147483647;
const RECIPE_HEADER = /^R1;(\d+);(\d+);(\d+);(\d+);([^;\n]+)$/;

function validProfessionName(name) {
  return typeof name === "string" && byteLen(name) >= 1 && byteLen(name) <= 64 && !/[;|]/.test(name)
    && !LUA_CONTROL.test(name) && sanitise.text(name)[0] === true;
}

// Reads a recipe list: { id, name, skill, max, learned, recipes } or null.
export function decodeRecipes(text) {
  if (typeof text !== "string") return null;
  const newline = text.indexOf("\n");
  const header = newline >= 0 ? text.slice(0, newline) : text;
  const body = newline >= 0 ? text.slice(newline + 1) : "";
  const m = RECIPE_HEADER.exec(header);
  if (!m || m[1].length > 10 || m[2].length > 4 || m[3].length > 4 || m[4].length > 10 || !validProfessionName(m[5])) {
    return null;
  }
  const entry = { id: Number(m[1]), name: m[5], skill: Number(m[2]), max: Number(m[3]), learned: Number(m[4]),
    recipes: [] };
  if (!isInteger(entry.id, 1, RECIPE_MAX_ID) || entry.learned > RECIPE_MAX_ID) return null;
  if (newline >= 0) {
    if (body === "" || /[^0-9a-z,]/.test(body) || body.includes(",,") || body.startsWith(",") || body.endsWith(",")) {
      return null;
    }
    let total = 0;
    for (const token of body.split(",")) {
      if (token.length > 6) return null;
      const gap = parseInt(token, 36);
      if (gap < 1) return null;
      total += gap;
      if (total > RECIPE_MAX_ID) return null;
      entry.recipes.push(total);
    }
  }
  return entry;
}

// Each member's newest list per profession: [{ author, note, profession }],
// by profession name, then author.
export function recipeLists(board) {
  const newest = new Map();
  for (const note of Object.values(board.notes || {})) {
    if (note.deleted || note.kind !== RECIPES_KIND) continue;
    const profession = decodeRecipes(note.text);
    if (!profession) continue;
    const key = `${note.author}\n${profession.id}`;
    const held = newest.get(key);
    if (!held || compareNote(note, held.note) > 0) newest.set(key, { author: note.author, note, profession });
  }
  return [...newest.values()].sort((a, b) => compare(a.profession.name, b.profession.name)
    || compare(a.author, b.author));
}

// Quest logs -------------------------------------------------------------------------

export const QUESTS_KIND = "quests";
export const QUESTS_MAX = 50;

// The quests in a log's text, as { id, level } in the order stored.
export function decodeQuests(text) {
  const quests = [];
  for (const m of (text || "").matchAll(/(\d+):(\d+)/g)) {
    const id = Number(m[1]);
    const level = Number(m[2]);
    if (isInteger(id, 1, 999999999) && isInteger(level, 0, 999)) {
      quests.push({ id, level });
      if (quests.length >= QUESTS_MAX) break;
    }
  }
  return quests;
}

// Each character's quest log: author -> note (the newer if there are two).
export function questLogs(board) {
  const logs = new Map();
  for (const note of Object.values(board.notes || {})) {
    if (note.deleted || note.kind !== QUESTS_KIND) continue;
    const held = logs.get(note.author);
    if (!held || compareVersion(note, held) > 0) logs.set(note.author, note);
  }
  return logs;
}

// Gear feed and ordinary notes ------------------------------------------------------------

export const GEAR_SHOWN = 50;

// Live gear entries, newest first (Store.gear).
export function gear(board) {
  return Object.values(board.notes || {})
    .filter((n) => !n.deleted && n.kind === "gear")
    .sort((a, b) => b.created - a.created || compare(b.id, a.id));
}

// Live ordinary notes, oldest first (Store.notes).
export function notes(board) {
  return Object.values(board.notes || {})
    .filter((n) => !n.deleted && n.kind === undefined)
    .sort((a, b) => a.created - b.created || compare(a.id, b.id));
}

// Members who aren't removed: the owner first, then by name (Store.members).
export function members(board) {
  return Object.values(board.members || {})
    .filter((m) => !m.removed)
    .sort((a, b) => (a.role !== b.role ? (a.role === "owner" ? -1 : 1) : compare(a.name, b.name)));
}
