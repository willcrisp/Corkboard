// End to end: the real API (python -m corkboard_api.app, serving web/public
// with CORK_WEB) and the app in headless Chromium. A demo board is pushed the
// way a member's companion would; the app joins it, reads every tab, writes
// notes and player notes, survives a reload, queues edits while offline, and
// picks up changes made "in game" afterwards.
//
// Needs the API installed (pip install -e shared/python -e api) and
// Playwright's Chromium. Run from web/: npm run e2e

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";

import { BOARD, demoBoard, pushDemo } from "./demo.mjs";
import * as merge from "../public/js/core/merge.js";

const WEB = join(dirname(fileURLToPath(import.meta.url)), "..");
const ROOT = join(WEB, "..");
const PYTHON = process.env.PYTHON || "python3";

let api;
let base;
let dir;
let browser;
let invite;
const errors = [];

function freePort() {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function waitForHealth() {
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`${base}/v1/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("the API didn't start");
}

// Everything the server holds for the demo board, as the companion sees it.
async function serverNotes() {
  const res = await fetch(`${base}/v1/boards/${BOARD.id}/sync`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${BOARD.id}.${BOARD.secret}` },
    body: JSON.stringify({ cursor: 0, notes: [], members: [] }),
  });
  const body = await res.json();
  return Object.fromEntries(body.notes.map((n) => [n.id, n]));
}

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "corkboard-e2e-"));
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  api = spawn(PYTHON, ["-c", `import uvicorn; from corkboard_api.app import create_app; uvicorn.run(create_app(), host="127.0.0.1", port=${port}, log_level="warning")`], {
    cwd: ROOT,
    env: { ...process.env, CORK_DB: join(dir, "cork.db"), CORK_WEB: join(WEB, "public") },
    stdio: ["ignore", "inherit", "inherit"],
  });
  await waitForHealth();
  invite = await pushDemo(base);
  browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
});

after(async () => {
  await browser?.close();
  api?.kill();
  if (dir) rmSync(dir, { recursive: true, force: true });
});

async function open(context) {
  const page = await context.newPage();
  page.on("pageerror", (err) => errors.push(err.message));
  page.on("console", (msg) => {
    if (msg.type() === "error" && !/Failed to load resource/.test(msg.text())) errors.push(msg.text());
  });
  await page.goto(`${base}/`);
  return page;
}

test("join, read every tab, write, reload, work offline, and see game changes", async () => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 820 } });
  const page = await open(context);

  // Sign in with a free-text name and the invite.
  await page.fill('[aria-label="Your name"]', "Tester");
  await page.getByText("Your notes are signed Tester-Web.").waitFor();
  await page.fill('[aria-label="Invite"]', invite);
  await page.click("text=Join Board");
  await page.locator(".card").first().waitFor();
  assert.equal(await page.locator(".board-title").textContent(), "Molten Core prep");
  assert.equal(await page.locator(".card").count(), 7);
  assert.match(await page.locator(".status").textContent(), /Cloud synced/);

  // Links show in their quality colour, with a tooltip.
  const fiery = page.locator(".card a.link", { hasText: "[Fiery Core]" });
  assert.equal(await fiery.evaluate((el) => getComputedStyle(el).color), "rgb(163, 53, 238)");
  await fiery.hover();
  await page.locator(".tooltip", { hasText: "Item ID 17010" }).waitFor();

  // Search filters the cards.
  await page.fill('[aria-label="Search notes"]', "loot plan");
  assert.equal(await page.locator(".card").count(), 1);
  await page.fill('[aria-label="Search notes"]', "");

  // Every tab renders what the game wrote.
  await page.click('.tab:has-text("Members")');
  assert.equal(await page.locator(".table-row").count(), 5);
  assert.equal(await page.locator('[aria-label="Invite"]').inputValue(), invite);
  await page.click('.tab:has-text("Gear")');
  await page.locator(".list-row", { hasText: "Helm of Might" }).waitFor();
  await page.click('.tab:has-text("Professions")');
  await page.locator(".list-row", { hasText: "Leatherworking 47/75" }).waitFor();
  // Clicking a profession lists its recipes; clicking again closes it.
  await page.click('.profession-row:has-text("Leatherworking 47/75")');
  assert.equal(await page.locator(".recipe-row").count(), 8);
  await page.locator(".recipe-row", { hasText: "Handstitched Leather Belt" }).waitFor();
  await page.click('.profession-row:has-text("Leatherworking 47/75")');
  assert.equal(await page.locator(".recipe-row").count(), 0);
  await page.fill('[aria-label="Search recipes"]', "belt");
  await page.locator(".list-row", { hasText: "Handstitched Leather Belt" }).waitFor();
  await page.locator(".list-row", { hasText: "Level 5 · Leather" }).waitFor();
  await page.fill('[aria-label="Search recipes"]', "");
  // The level and armour filters list matching recipes from every member.
  await page.fill('[aria-label="Lowest level"]', "4");
  await page.fill('[aria-label="Highest level"]', "7");
  await page.click('.recipe-filters [role="checkbox"]:has-text("Leather")');
  assert.equal(await page.locator(".list-row").count(), 2);
  await page.click('.recipe-filters [role="checkbox"]:has-text("Plate")');
  await page.click('.recipe-filters [role="checkbox"]:has-text("Leather")');
  await page.getByText("No recipes match your search and filters.").waitFor();
  await page.click('.recipe-filters [role="checkbox"]:has-text("Plate")');
  await page.fill('[aria-label="Lowest level"]', "");
  await page.fill('[aria-label="Highest level"]', "");
  await page.locator(".profession-row", { hasText: "Leatherworking 47/75" }).waitFor();
  await page.click('.tab:has-text("Quests")');
  await page.click('.members-col button:has-text("Kaelthra")');
  await page.locator(".list-row", { hasText: "Attunement to the Core" }).waitFor();
  await page.click('.tab:has-text("Players")');
  assert.equal(await page.locator(".player-row").count(), 3);

  // A new player note.
  await page.click("text=Add Player");
  await page.fill('[aria-label="Character"]', "Leeroy");
  await page.click('[role="radio"]:has-text("Avoid")');
  await page.fill('[aria-label="Why"]', "Charged in early.");
  await page.click('.dialog button:has-text("Save")');
  await page.locator(".player-row", { hasText: "Leeroy" }).waitFor();

  // A new note with a link from the picker.
  await page.click('.tab:has-text("Notes")');
  await page.click("text=New Note");
  await page.fill('[aria-label="Note"]', "From the web: bring ");
  await page.click("text=Link…");
  await page.fill('[aria-label="Search links"]', "fiery");
  await page.click('.picker-list button:has-text("Fiery Core")');
  await page.click('.dialog button:has-text("Save")');
  await page.locator(".card", { hasText: "From the web" }).waitFor();

  // An edit to a note written in game.
  const repair = page.locator(".card", { hasText: "Repair before you zone in" });
  await repair.hover();
  await repair.locator('[aria-label="Edit note"]').click();
  await page.fill('[aria-label="Note"]', "Repair first. Vendor at Thorium Point.");
  await page.click('.dialog button:has-text("Save")');
  await page.locator(".card", { hasText: "Repair first" }).waitFor();

  // All three reach the server within the push delay.
  let held;
  for (let i = 0; i < 50; i++) {
    held = await serverNotes();
    const texts = Object.values(held).map((n) => n.text);
    if (texts.some((t) => t.startsWith("From the web")) && texts.includes("Repair first. Vendor at Thorium Point.")
      && texts.some((t) => t.startsWith("P1;avoid;Leeroy"))) break;
    await page.waitForTimeout(200);
  }
  const mine = Object.values(held).find((n) => n.text.startsWith("From the web"));
  assert.equal(mine.author, "Tester-Web");
  assert.equal(mine.text, "From the web: bring |cffa335ee|Hitem:17010::::::::60:::::|h[Fiery Core]|h|r");
  assert.equal(Object.values(held).find((n) => n.text.startsWith("Repair first")).editor, "Tester-Web");
  assert.equal(Object.values(held).find((n) => n.text.startsWith("P1;avoid;Leeroy")).kind, "player");

  // A reload keeps the board and the name without joining again.
  await page.reload();
  await page.locator(".card", { hasText: "From the web" }).waitFor();

  // The service worker has cached the app, so it opens with no network.
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.waitForFunction(async () => (await caches.keys()).length > 0 && (await (await caches.open((await caches.keys())[0])).keys()).length >= 30);
  await context.setOffline(true);
  await page.reload();
  await page.locator(".card", { hasText: "From the web" }).waitFor();
  await page.locator(".status", { hasText: "Offline" }).waitFor();
  await context.setOffline(false);

  // Offline: the edit waits and says so, then goes when the network is back.
  await context.setOffline(true);
  await page.click("text=New Note");
  await page.fill('[aria-label="Note"]', "Written offline");
  await page.click('.dialog button:has-text("Save")');
  await page.locator(".status", { hasText: "1 change waiting" }).waitFor();
  await context.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await page.locator(".status", { hasText: "Cloud synced" }).waitFor();
  assert.ok(Object.values(await serverNotes()).some((n) => n.text === "Written offline"));

  // A change made in game (pushed by a companion) shows on the next sync.
  const game = demoBoard();
  merge.createNote(game, { id: "4e5f6a7b-0009", author: "Dorn-Stormrage", text: "Pushed from the game" }, Math.floor(Date.now() / 1000));
  await pushDemo(base, game);
  await page.click('.board-item:has-text("Molten Core prep")');
  await page.locator(".card", { hasText: "Pushed from the game" }).waitFor();

  await context.close();
  assert.deepEqual(errors, []);
});

test("the phone layout: board drawer and bottom tabs", async () => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const page = await open(context);
  await page.fill('[aria-label="Your name"]', "Phone");
  await page.fill('[aria-label="Invite"]', invite);
  await page.click("text=Join Board");
  await page.locator(".card").first().waitFor();
  // One column of cards, no horizontal scroll.
  const widths = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  assert.equal(widths[0], widths[1]);
  const boards = page.locator(".boards");
  assert.ok((await boards.boundingBox()).x < 0);
  await page.click('[aria-label="Boards"]');
  await page.waitForTimeout(300);
  assert.ok((await boards.boundingBox()).x >= 0);
  await page.click(".drawer-shade", { position: { x: 370, y: 400 } });
  for (const tab of ["Members", "Gear", "Professions", "Quests", "Players", "Notes"]) {
    await page.click(`.tab:has-text("${tab}")`);
    assert.equal(await page.locator(`.tab[aria-selected="true"]`).textContent(), tab);
  }
  await context.close();
  assert.deepEqual(errors, []);
});
