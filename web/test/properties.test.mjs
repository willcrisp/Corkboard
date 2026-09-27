// Property tests for the JavaScript merge core (docs/design.md §11), the same
// laws shared/python/tests/test_properties.py checks with Hypothesis: order
// independence, idempotence, associativity, the winner is the maximum, and
// convergence of 3-5 nodes plus a server under reordered, duplicated and
// dropped deliveries. A seeded PRNG keeps every run the same.

import { test } from "node:test";
import assert from "node:assert/strict";

import { clone, rng } from "./helpers.mjs";
import * as merge from "../public/js/core/merge.js";
import * as digest from "../public/js/core/digest.js";

const T0 = 1790000000;
const IDS = ["aaaaaaaa-1", "aaaaaaaa-2", "bbbbbbbb-1"];
const NAMES = ["Amy-Realm", "Bob-Realm", "bob-Realm", "Øystein-Realm", "Web User-Web"];
const TEXTS = ["a", "b", "|cffff0000c|r", "", "𝄞"];
const KINDS = ["gear", "recipes", "quests", "player"];
const RUNS = 300;

function randomNote(r) {
  const deleted = r() < 0.5;
  const note = {
    id: r.pick(IDS),
    author: r.pick(NAMES),
    created: T0 + r.int(0, 2),
    rev: r.pick([0, T0 + 1, T0 + 2, T0 + 3]), // rev 0 is invalid: dropped
    editor: r.pick(NAMES),
    text: deleted ? "" : r.pick(TEXTS),
    color: r.int(1, 2),
    deleted,
  };
  if (r() < 0.5) note.kind = r.pick(KINDS);
  return note;
}

function notes(r, max) {
  return Array.from({ length: r.int(0, max) }, () => randomNote(r));
}

function merged(records) {
  const board = { clock: 0 };
  for (const record of records) merge.applyNote(board, clone(record));
  return board;
}

test("merge is order independent", () => {
  const r = rng(1);
  for (let i = 0; i < RUNS; i++) {
    const records = notes(r, 8);
    assert.deepEqual(merged(r.shuffle(records.slice())), merged(records));
  }
});

test("merge is idempotent", () => {
  const r = rng(2);
  for (let i = 0; i < RUNS; i++) {
    const records = notes(r, 8);
    assert.deepEqual(merged(records.concat(records)), merged(records));
  }
});

test("merge is associative", () => {
  const r = rng(3);
  for (let i = 0; i < RUNS; i++) {
    const a = notes(r, 6);
    const b = notes(r, 6);
    const left = merged(a);
    for (const note of b) merge.applyNote(left, clone(note));
    assert.deepEqual(left, merged(a.concat(b)));
  }
});

test("the winner is the maximum", () => {
  const r = rng(4);
  for (let i = 0; i < RUNS; i++) {
    const records = notes(r, 6);
    const board = merged(records);
    for (const [id, winner] of Object.entries(board.notes || {})) {
      for (const record of records) {
        if (record.id === id && record.rev >= 1) assert.ok(merge.compareNote(winner, record) >= 0);
      }
    }
  }
});

test("3-5 nodes and a server converge", () => {
  const r = rng(5);
  for (let run = 0; run < 150; run++) {
    const size = r.int(3, 5);
    const names = Array.from({ length: size }, (_, i) => `Node${i}-Realm`);
    const nodes = Array.from({ length: size }, () => ({ clock: 0 }));
    const server = { clock: 0 };
    const counters = new Array(size).fill(0);
    let inFlight = [];
    let now = T0;
    const steps = r.int(1, 40);
    for (let step = 0; step < steps; step++) {
      const who = r.int(0, size - 1);
      const kind = r.pick(["create", "edit", "delete"]);
      now += r.int(0, 30);
      const board = nodes[who];
      const live = Object.keys(board.notes || {}).filter((id) => !board.notes[id].deleted).sort();
      let record;
      if (kind === "create" || live.length === 0) {
        counters[who] += 1;
        const id = `${who.toString(16).padStart(8, "0")}-${String(counters[who]).padStart(4, "0")}`;
        [record] = merge.createNote(board, { id, author: names[who], text: `n${counters[who]}` }, now);
      } else if (kind === "edit") {
        [record] = merge.editNote(board, r.pick(live), { text: `e${now}` }, names[who], now);
      } else {
        [record] = merge.deleteNote(board, r.pick(live), names[who], now);
      }
      assert.ok(record);
      for (let receiver = 0; receiver <= size; receiver++) {
        if (receiver === who) continue;
        const copies = r.pick([0, 1, 1, 2]);
        for (let c = 0; c < copies; c++) inFlight.push([receiver, clone(record)]);
      }
      r.shuffle(inFlight);
      inFlight = inFlight.filter(([receiver, rec]) => {
        if (r() < 0.5) {
          merge.applyNote(receiver === size ? server : nodes[receiver], rec);
          return false;
        }
        return true;
      });
    }
    // Heal through the server (the cloud path the web app uses), both ways.
    for (const node of nodes) for (const note of Object.values(node.notes || {})) merge.applyNote(server, clone(note));
    for (const node of nodes) for (const note of Object.values(server.notes || {})) merge.applyNote(node, clone(note));
    const target = digest.compute(server.notes || {}).digest;
    for (const node of nodes) {
      assert.equal(digest.compute(node.notes || {}).digest, target);
      assert.deepEqual(node.notes, server.notes);
    }
  }
});
