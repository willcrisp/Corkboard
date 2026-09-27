// Shared test-vector loading, as shared/python/tests/conftest.py does it.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { fromBytes } from "../public/js/core/util.js";

const HERE = dirname(fileURLToPath(import.meta.url));
export const VECTORS = join(HERE, "..", "..", "shared", "test-vectors");

export function load(name) {
  return JSON.parse(readFileSync(join(VECTORS, name), "utf8"));
}

function hexBytes(hex) {
  const out = [];
  for (let i = 0; i < hex.length; i += 2) out.push(parseInt(hex.slice(i, i + 2), 16));
  return out;
}

// A case's input: input (or the bytes of input_hex), repeated, then append.
export function textInput(c) {
  let value = "input_hex" in c ? fromBytes(hexBytes(c.input_hex)) : c.input;
  if (typeof value === "string") value = value.repeat(c.repeat ?? 1) + (c.append ?? "");
  return value;
}

export function record(base, c) {
  if ("input" in c) return c.input;
  const out = { ...base, ...(c.patch || {}) };
  for (const key of c.remove || []) delete out[key];
  return out;
}

export function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

export function* permutations(list) {
  if (list.length <= 1) {
    yield list.slice();
    return;
  }
  for (let i = 0; i < list.length; i++) {
    const rest = list.slice(0, i).concat(list.slice(i + 1));
    for (const p of permutations(rest)) yield [list[i], ...p];
  }
}

// A small seeded PRNG (mulberry32) so property tests are repeatable.
export function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  next.int = (lo, hi) => lo + Math.floor(next() * (hi - lo + 1));
  next.pick = (list) => list[Math.floor(next() * list.length)];
  next.shuffle = (list) => {
    for (let i = list.length - 1; i > 0; i--) {
      const j = Math.floor(next() * (i + 1));
      [list[i], list[j]] = [list[j], list[i]];
    }
    return list;
  };
  return next;
}
