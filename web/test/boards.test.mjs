// The board store against a fake sync API that behaves like api/ (merge,
// sequence numbers, paging, 401 / 409), so joining, local edits, pending
// changes, offline use and convergence with the companion's path are checked
// without a server.

import { test } from "node:test";
import assert from "node:assert/strict";

import { Boards } from "../public/js/app/boards.js";
import { ApiError } from "../public/js/app/api.js";
import { MemoryStorage } from "../public/js/app/storage.js";
import * as invite from "../public/js/core/invite.js";
import * as merge from "../public/js/core/merge.js";
import * as sanitise from "../public/js/core/sanitise.js";
import { compute } from "../public/js/core/digest.js";
import { clone } from "./helpers.mjs";

const ID = "k3f9x2m7q1pz8c4w";
const SECRET = "fS9vKerR2tBXp7qGmLzxW4nD";
const INVITE = invite.encode({ id: ID, secret: SECRET, owner: "Will-Stormrage" });
const T0 = 1790000000;

class FakeApi {
  constructor({ page = 500 } = {}) {
    this.page = page;
    this.boards = new Map();
    this.offline = false;
    this.calls = [];
  }

  host(id, secret) {
    this.boards.set(id, { secret, seq: 0, notes: new Map(), members: new Map(), meta: null, metaSeq: 0 });
    return this.boards.get(id);
  }

  async register(board) {
    this.calls.push("register");
    if (this.offline) throw new ApiError(0, "offline");
    if (this.boards.has(board.id)) throw new ApiError(409, "exists");
    this.host(board.id, board.secret);
    return { id: board.id };
  }

  async sync(board, body) {
    this.calls.push("sync");
    if (this.offline) throw new ApiError(0, "offline");
    const held = this.boards.get(board.id);
    if (!held || held.secret !== board.secret) throw new ApiError(401, "unauthorised");
    body = clone(body);
    const rejected = [];
    for (const record of body.notes) {
      const [clean, reason] = sanitise.note(record);
      if (!clean) {
        rejected.push({ kind: "note", id: record.id, reason });
        continue;
      }
      const row = held.notes.get(clean.id);
      if (row && merge.compareNote(clean, row.note) <= 0) continue;
      held.notes.set(clean.id, { note: clean, seq: ++held.seq });
    }
    for (const record of body.members) {
      const [clean] = sanitise.member(record);
      const row = clean && held.members.get(clean.name);
      if (!clean || (row && merge.compareMember(clean, row.member) <= 0)) continue;
      held.members.set(clean.name, { member: clean, seq: ++held.seq });
    }
    if (body.meta) {
      const [clean] = sanitise.meta(body.meta);
      if (clean && (!held.meta || merge.compareMeta(clean, held.meta) > 0)) {
        held.meta = clean;
        held.metaSeq = ++held.seq;
      }
    }
    const rows = [...held.notes.values()].filter((r) => r.seq > body.cursor).sort((a, b) => a.seq - b.seq);
    const more = rows.length > this.page;
    const page = rows.slice(0, this.page);
    const upto = more ? page[page.length - 1].seq : held.seq;
    return {
      cursor: upto,
      more,
      notes: page.map((r) => clone(r.note)),
      members: [...held.members.values()].filter((r) => r.seq > body.cursor && r.seq <= upto).map((r) => clone(r.member)),
      meta: held.meta && body.cursor < held.metaSeq && held.metaSeq <= upto ? clone(held.meta) : null,
      rejected,
    };
  }

  // What the desktop companion would push for a member in game.
  push(board) {
    return this.sync({ id: ID, secret: SECRET }, { cursor: 0, notes: Object.values(board.notes || {}),
      members: Object.values(board.members || {}), meta: board.meta || null });
  }
}

function make({ api = new FakeApi(), storage = new MemoryStorage(), time = { t: T0 }, seed = 0.1 } = {}) {
  const random = () => seed;
  return { api, storage, time, boards: new Boards({ storage, api, clock: () => time.t, random }) };
}

function gameBoard() {
  const board = { clock: 0 };
  merge.setMeta(board, "Molten Core prep", "Will-Stormrage", T0 - 100);
  merge.setMember(board, "Will-Stormrage", "owner", false, "Will-Stormrage", T0 - 100);
  merge.createNote(board, { id: "1f2e3d4c-0001", author: "Will-Stormrage", text: "Bring |cffa335ee|Hitem:17010|h[Fiery Core]|h|r" }, T0 - 50);
  return board;
}

test("joining needs a name and a valid invite", async () => {
  const { boards } = make();
  await boards.load();
  assert.match(boards.settings.prefix, /^[0-9a-f]{8}$/);
  assert.deepEqual(await boards.join("hello"), [null, "invite"]);
  const [board] = await boards.join(INVITE);
  assert.equal(board.id, ID);
  assert.equal(boards.current, board);
  assert.deepEqual(await boards.addNote(ID, "hi", 1), [null, "author"]);
  assert.deepEqual(await boards.setName("Will"), ["Will-Web", null]);
});

test("the first sync registers an unknown board, then pulls what the game pushed", async () => {
  const { api, boards } = make();
  await boards.load();
  await boards.setName("Will");
  await boards.join(INVITE);
  await boards.sync(ID);
  assert.deepEqual(api.calls, ["sync", "register", "sync"]);
  assert.equal(boards.get(ID).sync.state, "synced");
  await api.push(gameBoard());
  await boards.sync(ID);
  const board = boards.get(ID);
  assert.equal(board.meta.name, "Molten Core prep");
  assert.equal(board.notes["1f2e3d4c-0001"].text.includes("Fiery Core"), true);
  assert.equal(board.members["Will-Stormrage"].role, "owner");
});

test("a wrong secret is refused, and a new invite fixes it", async () => {
  const { api, boards } = make();
  api.host(ID, "SomeOtherSecret0000000000");
  await boards.load();
  await boards.setName("Will");
  await boards.join(INVITE);
  await boards.sync(ID);
  assert.equal(boards.get(ID).sync.state, "refused");
  api.boards.get(ID).secret = SECRET;
  await boards.join(INVITE); // the re-sent invite clears the refusal
  await boards.sync(ID);
  assert.equal(boards.get(ID).sync.state, "synced");
});

test("local edits wait while offline and go on the next sync", async () => {
  const { api, boards, time } = make();
  api.host(ID, SECRET);
  await api.push(gameBoard());
  await boards.load();
  await boards.setName("Mira");
  await boards.join(INVITE);
  await boards.sync(ID);

  api.offline = true;
  time.t = T0 + 10;
  const [note] = await boards.addNote(ID, "Posted from my phone. || pipes are fine", 3);
  assert.match(note.id, /^[0-9a-f]{8}-0001$/);
  assert.equal(note.author, "Mira-Web");
  const [edit] = await boards.editNote(ID, "1f2e3d4c-0001", { text: "Bring 2x |cffa335ee|Hitem:17010|h[Fiery Core]|h|r" });
  assert.equal(edit.editor, "Mira-Web");
  assert.ok(edit.rev > T0 - 50);
  await boards.rename(ID, "MC prep");
  await boards.sync(ID);
  const board = boards.get(ID);
  assert.equal(board.sync.state, "offline");
  assert.equal(boards.pendingCount(board), 3);

  api.offline = false;
  await boards.sync(ID);
  assert.equal(board.sync.state, "synced");
  assert.equal(boards.pendingCount(board), 0);
  const server = api.boards.get(ID);
  assert.equal(server.notes.get(note.id).note.text, note.text);
  assert.equal(server.notes.get("1f2e3d4c-0001").note.editor, "Mira-Web");
  assert.equal(server.meta.name, "MC prep");
});

test("an unchanged save writes nothing; deletes are tombstones", async () => {
  const { api, boards, time } = make();
  api.host(ID, SECRET);
  await api.push(gameBoard());
  await boards.load();
  await boards.setName("Bob");
  await boards.join(INVITE);
  await boards.sync(ID);
  const before = boards.get(ID).notes["1f2e3d4c-0001"];
  const [same] = await boards.editNote(ID, before.id, { text: before.text, color: before.color });
  assert.equal(same.rev, before.rev);
  assert.equal(boards.pendingCount(boards.get(ID)), 0);
  time.t += 5;
  const [gone] = await boards.deleteNote(ID, before.id);
  assert.equal(gone.deleted, true);
  assert.equal(gone.text, "");
  await boards.sync(ID);
  assert.equal(api.boards.get(ID).notes.get(before.id).note.deleted, true);
});

test("player notes use the game's format", async () => {
  const { api, boards } = make();
  api.host(ID, SECRET);
  await boards.load();
  await boards.setName("Will");
  await boards.join(INVITE);
  assert.deepEqual(await boards.addPlayer(ID, "Gank;alot", "avoid", ""), [null, "player_name"]);
  const [note] = await boards.addPlayer(ID, " Gankalot ", "avoid", "Ninja.");
  assert.equal(note.kind, "player");
  assert.equal(note.text, "P1;avoid;Gankalot\nNinja.");
  const [edited] = await boards.editPlayer(ID, note.id, "Gankalot", "good", "");
  assert.equal(edited.text, "P1;good;Gankalot");
});

test("large boards page in, and state survives a reload", async () => {
  const api = new FakeApi({ page: 7 });
  api.host(ID, SECRET);
  const game = { clock: 0 };
  for (let i = 1; i <= 30; i++) {
    merge.createNote(game, { id: `1f2e3d4c-${String(i).padStart(4, "0")}`, author: "Will-Stormrage", text: `n${i}` }, T0 + i);
  }
  await api.push(game);
  const first = make({ api });
  await first.boards.load();
  await first.boards.setName("Will");
  await first.boards.join(INVITE);
  await first.boards.sync(ID);
  assert.equal(Object.keys(first.boards.get(ID).notes).length, 30);
  assert.equal(compute(first.boards.get(ID).notes).digest, compute(game.notes).digest);

  const again = make({ api, storage: first.storage });
  await again.boards.load();
  assert.equal(again.boards.me, "Will-Web");
  assert.equal(again.boards.settings.prefix, first.boards.settings.prefix);
  assert.equal(Object.keys(again.boards.get(ID).notes).length, 30);
  assert.equal(again.boards.get(ID).cursor, first.boards.get(ID).cursor);
});

test("two web devices and the game converge through the server", async () => {
  const api = new FakeApi({ page: 3 });
  api.host(ID, SECRET);
  const game = gameBoard();
  await api.push(game);
  const a = make({ api, seed: 0.1 });
  const b = make({ api, seed: 0.7 });
  for (const [dev, name] of [[a, "Amy"], [b, "Ben"]]) {
    await dev.boards.load();
    await dev.boards.setName(name);
    await dev.boards.join(INVITE);
    await dev.boards.sync(ID);
  }
  a.time.t = b.time.t = T0 + 100;
  await a.boards.editNote(ID, "1f2e3d4c-0001", { text: "Amy's version" });
  await b.boards.editNote(ID, "1f2e3d4c-0001", { text: "Ben's version" });
  await a.boards.addNote(ID, "from Amy", 1);
  await b.boards.addNote(ID, "from Ben", 2);
  merge.editNote(game, "1f2e3d4c-0001", { text: "Will's version" }, "Will-Stormrage", T0 + 99);
  await api.push(game);
  for (let i = 0; i < 2; i++) {
    await a.boards.sync(ID);
    await b.boards.sync(ID);
  }
  const server = Object.fromEntries([...api.boards.get(ID).notes].map(([id, r]) => [id, r.note]));
  assert.deepEqual(a.boards.get(ID).notes, server);
  assert.deepEqual(b.boards.get(ID).notes, server);
  // Same rev: "Ben-Web" > "Amy-Web" byte-wise, so Ben's edit wins everywhere.
  assert.equal(server["1f2e3d4c-0001"].text, "Ben's version");
  assert.notEqual(a.boards.settings.prefix, b.boards.settings.prefix);
  assert.equal(Object.keys(server).length, 3);
});

test("a change overtaken by a newer remote version doesn't stay pending", async () => {
  const { api, boards, time } = make();
  api.host(ID, SECRET);
  await api.push(gameBoard());
  await boards.load();
  await boards.setName("Amy");
  await boards.join(INVITE);
  await boards.sync(ID);
  api.offline = true;
  time.t = T0 + 10;
  await boards.editNote(ID, "1f2e3d4c-0001", { text: "Amy's edit" });
  // A newer version arrives from elsewhere before Amy's edit is pushed.
  const board = boards.get(ID);
  merge.applyNote(board, { ...board.notes["1f2e3d4c-0001"], rev: T0 + 20, editor: "Will-Stormrage", text: "Will's" });
  api.offline = false;
  await boards.sync(ID);
  assert.equal(boards.pendingCount(board), 0);
  assert.equal(api.boards.get(ID).notes.get("1f2e3d4c-0001").note.text, "Will's");
});

test("a refused board is retried when its invite is entered again", async () => {
  const { api, boards } = make();
  api.host(ID, "SomeOtherSecret0000000000");
  await boards.load();
  await boards.setName("Will");
  await boards.join(INVITE);
  await boards.sync(ID);
  assert.equal(boards.get(ID).sync.state, "refused");
  await boards.join(INVITE);
  assert.equal(boards.get(ID).sync.state, "new");
});
