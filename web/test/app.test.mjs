// The shipped files: the service worker caches all of them, and the page,
// manifest and stylesheet only point at files that exist.

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const PUBLIC = join(dirname(fileURLToPath(import.meta.url)), "..", "public");

function files(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path) : [relative(PUBLIC, path).split("\\").join("/")];
  });
}

test("the service worker caches every shipped file", () => {
  const sw = readFileSync(join(PUBLIC, "sw.js"), "utf8");
  const shell = JSON.parse(sw.slice(sw.indexOf("const SHELL = [") + 14, sw.indexOf("];", sw.indexOf("const SHELL")) + 1)
    .replace(/,\s*]$/, "]"));
  const expected = files(PUBLIC).filter((f) => f !== "sw.js" && !f.endsWith(".txt")).sort();
  assert.deepEqual(shell.filter((f) => f !== "./").sort(), expected);
});

test("references resolve", () => {
  const html = readFileSync(join(PUBLIC, "index.html"), "utf8");
  for (const [, ref] of html.matchAll(/(?:href|src)="([^"#]+)"/g)) assert.ok(existsSync(join(PUBLIC, ref)), ref);
  const manifest = JSON.parse(readFileSync(join(PUBLIC, "manifest.webmanifest"), "utf8"));
  for (const icon of manifest.icons) assert.ok(existsSync(join(PUBLIC, icon.src)), icon.src);
  const css = readFileSync(join(PUBLIC, "css", "corkboard.css"), "utf8");
  for (const [, ref] of css.matchAll(/url\(([^)]+)\)/g)) assert.ok(existsSync(join(PUBLIC, "css", ref)), ref);
});

test("every app module's imports resolve", () => {
  for (const file of files(PUBLIC).filter((f) => f.endsWith(".js") && f !== "sw.js")) {
    const src = readFileSync(join(PUBLIC, file), "utf8");
    for (const [, ref] of src.matchAll(/from "(\.[^"]+)"/g)) {
      assert.ok(existsSync(join(PUBLIC, dirname(file), ref)), `${file} -> ${ref}`);
    }
  }
});
