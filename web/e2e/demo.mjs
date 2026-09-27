// A demo board, pushed to a running API the way a member's companion would:
// notes with links, gear posts, recipe lists, a quest log, player notes, the
// roster and the board's name. The e2e tests use it, and so can a local run:
//
//   node web/e2e/demo.mjs http://127.0.0.1:8000
//
// prints the invite to paste into the web app.

import * as merge from "../public/js/core/merge.js";
import * as invite from "../public/js/core/invite.js";

export const BOARD = { id: "k3f9x2m7q1pz8c4w", secret: "fS9vKerR2tBXp7qGmLzxW4nD", owner: "Will-Stormrage" };

const item = (id, name, color) => `|cff${color}|Hitem:${id}::::::::60:::::|h[${name}]|h|r`;
const quest = (id, level, name) => `|cffffff00|Hquest:${id}:${level}|h[${name}]|h|r`;
const EPIC = "a335ee";
const RARE = "0070dd";
const COMMON = "ffffff";

function recipes(profession, skill, max, ids) {
  ids = [...ids].sort((a, b) => a - b);
  let previous = 0;
  const gaps = ids.map((id) => {
    const gap = (id - previous).toString(36);
    previous = id;
    return gap;
  });
  return `R1;${profession.id};${skill};${max};${ids.length};${profession.name}\n${gaps.join(",")}`;
}

export function demoBoard(now = Math.floor(Date.now() / 1000)) {
  const board = { clock: 0, notes: {}, members: {}, meta: null };
  // Changes are made oldest first: the board clock (§4.3) never goes back, so
  // a change made after a newer one would get the newer one's time.
  const ops = [];
  const at = (ago, fn) => ops.push([ago, fn]);
  const add = (prefix, n, author, ago, text, color = 1, kind) => at(ago, () => {
    const id = n === 0 ? `${prefix}-0` : `${prefix}-${String(n).padStart(4, "0")}`;
    const [note, reason] = merge.createNote(board, { id, author, text, color, kind }, now - ago);
    if (!note) throw new Error(`${id}: ${reason}`);
  });
  const W = "1f2e3d4c", B = "5a6b7c8d", K = "9e8d7c6b", M = "0a1b2c3d", D = "4e5f6a7b";
  const will = "Will-Stormrage", bob = "Bob-Stormrage", kael = "Kaelthra-Stormrage", mira = "Mira-Stormrage",
    dorn = "Dorn-Stormrage";

  at(9 * 86400, () => merge.setMeta(board, "Molten Core prep", will, now - 9 * 86400));
  for (const [name, role, ago] of [[will, "owner", 9 * 86400], [bob, "member", 8 * 86400], [kael, "member", 7 * 86400],
    [mira, "member", 6 * 86400], [dorn, "member", 5 * 86400]]) {
    at(ago - 1, () => merge.setMember(board, name, role, false, name, now - ago + 1));
  }

  add(W, 1, will, 7200, `Need 4x ${item(7078, "Essence of Fire", COMMON)} and 2x ${item(17010, "Fiery Core", EPIC)} for the fire-res cloak. Anyone with spares, mail Will.`, 1);
  add(B, 1, bob, 2400, `Everyone bring 3x ${item(13457, "Greater Fire Protection Potion", COMMON)}. Swap to fire-res gear before the first boss.`, 2);
  const attune = `${quest(7848, 60, "Attunement to the Core")} done: Bob, Kaelthra, Will. Still need Mira and Dorn.`;
  add(K, 1, kael, 7000, `${quest(7848, 60, "Attunement to the Core")} done: Bob, Kaelthra, Will.`, 3);
  at(840, () => merge.editNote(board, `${K}-0001`, { text: attune }, mira, now - 840));
  add(W, 2, will, 86400, `Raid Tuesday 7:30pm server time. Flasks if you have them, otherwise ${item(13452, "Elixir of the Mongoose", COMMON)}.`, 4);
  add(D, 1, dorn, 600, `Loot plan: ${item(19137, "Onslaught Girdle", EPIC)} to Dorn first, then Bob. Rolls for everything else.`, 5);
  add(M, 1, mira, 18000, "Repair before you zone in. There's a repair vendor at Thorium Point if you're coming from the south.", 1);

  add(B, 2, bob, 1800, item(16866, "Helm of Might", EPIC), 1, "gear");
  add(K, 2, kael, 5400, item(18814, "Choker of the Fire Lord", EPIC), 1, "gear");
  add(M, 2, mira, 30000, item(12930, "Briarwood Reed", RARE), 1, "gear");
  add(D, 2, dorn, 90000, item(13965, "Blackhand's Breadth", RARE), 1, "gear");

  add(W, 3, will, 3 * 86400, recipes({ id: 165, name: "Leatherworking" }, 47, 75, [2108, 2152, 2149, 2153, 3753, 9058, 9059, 1263079]), 1, "recipes");
  add(B, 3, bob, 2 * 86400, recipes({ id: 171, name: "Alchemy" }, 280, 300, [17555, 17556, 17557, 17570, 17573, 17574, 17575, 17577]), 1, "recipes");
  add(W, 4, will, 3 * 3600, `Crafting |cffffd000|Henchant:3753|h[Leatherworking: Handstitched Leather Belt]|h|r for anyone levelling. Bob has |cffffd000|Henchant:17573|h[Alchemy: Greater Arcane Elixir]|h|r.`, 2);

  add(K, 0, kael, 900, "7848:60,6822:60,6823:60,4262:56,5063:58", 1, "quests");
  add(B, 0, bob, 3000, "7848:60,5063:58,8288:60", 1, "quests");

  add(W, 5, will, 4 * 86400, `P1;avoid;Gankalot\nRolled need on ${item(18814, "Choker of the Fire Lord", EPIC)} as a hunter and left the group.`, 1, "player");
  add(B, 4, bob, 2 * 86400, "P1;good;Healbot Lightbringer-Stormrage\nGreat healer, knows every fight. Invite again.", 1, "player");
  add(M, 3, mira, 86400, "P1;avoid;Pullmaster\nPulls before the tank is ready.", 1, "player");

  ops.sort((a, b) => b[0] - a[0]);
  for (const [, fn] of ops) fn();
  return board;
}

export async function pushDemo(base, board = demoBoard()) {
  const headers = { "Content-Type": "application/json" };
  const reg = await fetch(`${base}/v1/boards`, { method: "POST", headers, body: JSON.stringify({ id: BOARD.id, secret: BOARD.secret }) });
  if (reg.status !== 201 && reg.status !== 409) throw new Error(`register: ${reg.status}`);
  const res = await fetch(`${base}/v1/boards/${BOARD.id}/sync`, {
    method: "POST",
    headers: { ...headers, Authorization: `Bearer ${BOARD.id}.${BOARD.secret}` },
    body: JSON.stringify({ cursor: 0, notes: Object.values(board.notes), members: Object.values(board.members), meta: board.meta }),
  });
  if (!res.ok) throw new Error(`sync: ${res.status}`);
  const body = await res.json();
  if (body.rejected.length) throw new Error(`rejected: ${JSON.stringify(body.rejected)}`);
  return invite.encode(BOARD);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const base = process.argv[2] || "http://127.0.0.1:8000";
  console.log(await pushDemo(base));
}
