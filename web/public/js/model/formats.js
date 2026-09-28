// The note kinds the game writes, read (and for player notes, written) the
// same way the addon does: player notes (Core/Players.lua, §9.4), recipe
// lists (Core/Recipes.lua, §9.2), quest logs with completed quests and
// chains (Store.decodeQuests and decodeDone, §9.3) and the gear feed
// (Store.gear, §9.1).

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
const RECIPE_HEADER = /^R([12]);(\d+);(\d+);(\d+);(\d+);([^;\n]+)$/;
const RECIPE_DETAIL = /^(\d{0,3})([clmp]?)$/;
// Armour types a recipe's item can have, in the tab's order (§9.2).
export const ARMOUR = ["cloth", "leather", "mail", "plate"];
export const ARMOUR_NAMES = { cloth: "Cloth", leather: "Leather", mail: "Mail", plate: "Plate" };
const ARMOUR_OF = { c: "cloth", l: "leather", m: "mail", p: "plate" };

function validProfessionName(name) {
  return typeof name === "string" && byteLen(name) >= 1 && byteLen(name) <= 64 && !/[;|]/.test(name)
    && !LUA_CONTROL.test(name) && sanitise.text(name)[0] === true;
}

// Reads a recipe list: { id, name, skill, max, learned, recipes, details } or
// null. details maps a recipe id to { level, armour } for the item it makes,
// from an R2 list's third line (see Core/Recipes.lua).
export function decodeRecipes(text) {
  if (typeof text !== "string") return null;
  const newline = text.indexOf("\n");
  const header = newline >= 0 ? text.slice(0, newline) : text;
  let body = newline >= 0 ? text.slice(newline + 1) : "";
  let third = null;
  const second = body.indexOf("\n");
  if (second >= 0) {
    third = body.slice(second + 1);
    body = body.slice(0, second);
  }
  const match = RECIPE_HEADER.exec(header);
  if (!match) return null;
  const [, version, id, skill, max, learned, name] = match;
  if ((third !== null && version !== "2") || id.length > 10 || skill.length > 4 || max.length > 4
    || learned.length > 10 || !validProfessionName(name)) {
    return null;
  }
  const entry = { id: Number(id), name, skill: Number(skill), max: Number(max), learned: Number(learned),
    recipes: [], details: {} };
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
  if (entry.recipes.length > entry.learned) return null;
  if (third !== null) {
    const tokens = third.split(",");
    if (tokens.length !== entry.recipes.length) return null;
    for (const [i, token] of tokens.entries()) {
      const d = RECIPE_DETAIL.exec(token);
      if (!d || d[1].startsWith("0")) return null;
      if (token === "") continue;
      const detail = {};
      if (d[1]) detail.level = Number(d[1]);
      if (d[2]) detail.armour = ARMOUR_OF[d[2]];
      entry.details[entry.recipes[i]] = detail;
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

const QUEST_ID_MAX = 999999999;
const QUEST_LEVEL_MAX = 999;
const TIME_MAX = 2147483647;

function questNumber(digits, low, high) {
  if (!digits) return null;
  const n = Number(digits);
  return isInteger(n, low, high) ? n : null;
}

// The quests in a log's text, as { id, level } in the order stored, with
// prev for a quest known to follow another ("id:level/prev"). Only the first
// line is the log; the completed quests follow on the next (decodeDone).
export function decodeQuests(text) {
  const quests = [];
  const line = (text || "").split("\n")[0];
  for (const m of line.matchAll(/(\d+):(\d+)\/?(\d*)/g)) {
    const id = questNumber(m[1], 1, QUEST_ID_MAX);
    const level = questNumber(m[2], 0, QUEST_LEVEL_MAX);
    const prev = questNumber(m[3], 1, QUEST_ID_MAX);
    if (id !== null && level !== null) {
      const quest = { id, level };
      if (prev !== null && prev !== id) quest.prev = prev;
      quests.push(quest);
      if (quests.length >= QUESTS_MAX) break;
    }
  }
  return quests;
}

export const QUESTS_DONE_MAX = 30;

// The quests a member has turned in, from the "D1;" line of their log:
// { id, level, at, prev? }, newest first (Store.decodeDone).
export function decodeDone(text) {
  const m = /(?:^|\n)D1;([^\n]*)/.exec(text || "");
  const entries = [];
  const seen = new Set();
  for (const item of (m ? m[1] : "").split(",")) {
    const f = /^(\d+)\.(\d+)\.(\d+)\.?(\d*)$/.exec(item);
    if (!f) continue;
    const id = questNumber(f[1], 1, QUEST_ID_MAX);
    const level = questNumber(f[2], 0, QUEST_LEVEL_MAX);
    const at = questNumber(f[3], 0, TIME_MAX);
    const prev = questNumber(f[4], 1, QUEST_ID_MAX);
    if (id === null || level === null || at === null || seen.has(id)) continue;
    seen.add(id);
    const entry = { id, level, at };
    if (prev !== null && prev !== id) entry.prev = prev;
    entries.push(entry);
    if (entries.length >= QUESTS_DONE_MAX) break;
  }
  return entries;
}

// Every quest link on the board (id -> the quest it follows), from each
// member's log and completed quests; where they disagree, the link most
// hold, then the lower id. Also each quest's level where one is known
// (Store:questLinks, less the addon's own learned links).
export function questLinks(board) {
  const votes = new Map();
  const levels = new Map();
  const add = (id, level, prev) => {
    if (level > 0) levels.set(id, level);
    if (prev === undefined) return;
    const counts = votes.get(id) || new Map();
    counts.set(prev, (counts.get(prev) || 0) + 1);
    votes.set(id, counts);
  };
  for (const log of questLogs(board).values()) {
    for (const q of decodeQuests(log.text)) add(q.id, q.level, q.prev);
    for (const e of decodeDone(log.text)) add(e.id, e.level, e.prev);
  }
  const links = new Map();
  for (const [id, counts] of votes) {
    let best = null;
    let most = 0;
    for (const [prev, n] of counts) {
      if (n > most || (n === most && prev < best)) [best, most] = [prev, n];
    }
    links.set(id, best);
  }
  return { links, levels };
}

export const CHAIN_MAX = 20;

// The quests before `id` in its chain, oldest first (View.chainBefore).
export function chainBefore(links, id) {
  const before = [];
  const seen = new Set([id]);
  let prev = links.get(id);
  while (prev !== undefined && !seen.has(prev) && before.length < CHAIN_MAX) {
    seen.add(prev);
    before.unshift(prev);
    prev = links.get(prev);
  }
  return before;
}

// Completed quests with each chain kept together: groups in the order of
// their newest turn-in, newest first within one. Rows in a group of two or
// more get up / down for the line joining them.
export function groupChains(entries, links) {
  const inList = new Set(entries.map((e) => e.id));
  const root = (id) => {
    const seen = new Set([id]);
    while (links.has(id) && inList.has(links.get(id)) && !seen.has(links.get(id))) {
      id = links.get(id);
      seen.add(id);
    }
    return id;
  };
  const groups = new Map();
  for (const entry of entries) {
    const key = root(entry.id);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry);
  }
  const out = [];
  for (const group of groups.values()) {
    group.forEach((entry, i) => {
      out.push({ ...entry, up: group.length > 1 && i > 0, down: group.length > 1 && i < group.length - 1 });
    });
  }
  return out;
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
