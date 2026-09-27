// Renders the PNG app icons from public/icons/icon.svg and tools/maskable.svg
// with Playwright's Chromium: node web/tools/render_icons.mjs
// Run it after changing either SVG; the PNGs are committed.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const WEB = join(dirname(fileURLToPath(import.meta.url)), "..");
const ICONS = join(WEB, "public", "icons");
const JOBS = [
  [join(ICONS, "icon.svg"), "icon-192.png", 192],
  [join(ICONS, "icon.svg"), "icon-512.png", 512],
  [join(WEB, "tools", "maskable.svg"), "icon-maskable-512.png", 512],
  [join(WEB, "tools", "maskable.svg"), "apple-touch-icon.png", 180],
];

const browser = await chromium.launch();
const page = await browser.newPage();
for (const [src, out, size] of JOBS) {
  const svg = readFileSync(src, "utf8").replace("<svg ", `<svg width="${size}" height="${size}" `);
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
  await page.screenshot({ path: join(ICONS, out), omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
}
await browser.close();
