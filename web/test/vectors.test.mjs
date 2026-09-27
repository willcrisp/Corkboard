// Every case in shared/test-vectors, as the Lua and Python suites run them.

import { test } from "node:test";
import assert from "node:assert/strict";

import { clone, load, permutations, record, textInput } from "./helpers.mjs";
import * as util from "../public/js/core/util.js";
import * as sanitise from "../public/js/core/sanitise.js";
import * as merge from "../public/js/core/merge.js";
import * as digest from "../public/js/core/digest.js";
import * as invite from "../public/js/core/invite.js";

const SANITISE = load("sanitise.json");
const MERGE = load("merge.json");
const DIGEST = load("digest.json");
const FNV = load("fnv1a32.json");
const INVITE = load("invite.json");
const FUZZ = load("sanitise_fuzz.json");

const label = (c, i) => c.name ?? String(i);

test("fnv1a32", () => {
  FNV.cases.forEach((c, i) => assert.equal(util.fnv1a32(textInput(c)), c.fnv1a32, label(c, i)));
});

test("sanitise text", () => {
  SANITISE.text.forEach((c, i) => {
    const [ok, reason] = sanitise.text(textInput(c));
    assert.equal(ok, c.ok, label(c, i));
    assert.equal(reason, c.reason ?? null, label(c, i));
  });
});

test("sanitise names", () => {
  SANITISE.name.forEach((c, i) => assert.equal(sanitise.name(textInput(c)), c.ok, label(c, i)));
  SANITISE.board_name.forEach((c, i) => assert.equal(sanitise.boardName(textInput(c)), c.ok, label(c, i)));
});

for (const kind of ["note", "member", "meta"]) {
  test(`sanitise ${kind} records`, () => {
    const section = SANITISE[kind];
    for (const c of section.cases) {
      const value = record(section.base, c);
      const [clean, reason] = sanitise[kind](value);
      if (c.ok) {
        assert.equal(reason, null, c.name);
        assert.deepEqual(clean, c.output ?? value, c.name);
        assert.notEqual(clean, value, c.name);
      } else {
        assert.equal(clean, null, c.name);
        assert.equal(reason, c.reason, c.name);
      }
    }
  });
}

test("sanitiser fuzz corpus", () => {
  FUZZ.text.forEach((c, i) => {
    const [ok, reason] = sanitise.text(textInput(c));
    assert.equal(ok, c.ok, `text ${i} ${c.input_hex}`);
    assert.equal(reason, c.reason ?? null, `text ${i} ${c.input_hex}`);
  });
  FUZZ.name.forEach((c, i) => assert.equal(sanitise.name(textInput(c)), c.ok, `name ${i} ${c.input_hex}`));
  FUZZ.board_name.forEach((c, i) => assert.equal(sanitise.boardName(textInput(c)), c.ok, `board ${i}`));
});

const SECTIONS = { notes: ["id", merge.applyNote], members: ["name", merge.applyMember] };

function boardFrom(spec, field, key) {
  const records = {};
  for (const r of spec[field] || []) records[r[key]] = clone(r);
  return { clock: spec.clock, [field]: records };
}

for (const field of ["notes", "members"]) {
  test(`merge ${field}`, () => {
    const [key, apply] = SECTIONS[field];
    for (const c of MERGE[field]) {
      const expected = {};
      for (const r of c.expect[field]) expected[r[key]] = r;
      let board = boardFrom(c.board, field, key);
      const results = c.apply.map((r) => {
        const [ok, reason] = apply(board, clone(r));
        return ok ? "stored" : reason;
      });
      assert.deepEqual(results, c.results, c.name);
      assert.equal(board.clock, c.expect.clock, c.name);
      assert.deepEqual(board[field], expected, c.name);
      // Every order, applied twice.
      for (const order of permutations(c.apply)) {
        board = boardFrom(c.board, field, key);
        for (let n = 0; n < 2; n++) for (const r of order) apply(board, clone(r));
        assert.equal(board.clock, c.expect.clock, c.name);
        assert.deepEqual(board[field], expected, c.name);
      }
    }
  });
}

test("merge meta", () => {
  for (const c of MERGE.meta) {
    const fresh = () => ({ clock: c.board.clock, meta: clone(c.board.meta) ?? null });
    let board = fresh();
    const results = c.apply.map((r) => {
      const [ok, reason] = merge.applyMeta(board, clone(r));
      return ok ? "stored" : reason;
    });
    assert.deepEqual(results, c.results, c.name);
    assert.equal(board.clock, c.expect.clock, c.name);
    assert.deepEqual(board.meta, c.expect.meta ?? null, c.name);
    for (const order of permutations(c.apply)) {
      board = fresh();
      for (let n = 0; n < 2; n++) for (const r of order) merge.applyMeta(board, clone(r));
      assert.deepEqual(board.meta, c.expect.meta ?? null, c.name);
    }
  }
});

test("digest", () => {
  for (const c of DIGEST.bucket) assert.equal(digest.bucket(c.id), c.bucket, c.id);
  for (const c of DIGEST.line) assert.equal(digest.line(c.note), c.line);
  for (const c of DIGEST.boards) {
    const result = digest.compute(c.notes);
    assert.equal(result.count, c.count, c.name);
    assert.deepEqual(result.buckets, c.buckets, c.name);
    assert.equal(result.digest, c.digest, c.name);
  }
});

test("invite encode", () => {
  for (const c of INVITE.encode) assert.equal(invite.encode(c.board), c.invite, c.name);
});

test("invite decode", () => {
  for (const c of INVITE.decode) {
    const [out, reason] = invite.decode(c.input);
    if (c.ok) {
      assert.deepEqual(out, c.output, c.name);
    } else {
      assert.equal(out, null, c.name);
      assert.equal(reason, c.reason, c.name);
    }
  }
});
