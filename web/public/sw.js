// The service worker: keeps the app itself (never board data, never the API)
// cached so it opens offline and installs as an app. Files are served from
// the cache and refreshed in the background, so a deploy shows on the next
// launch. web/test/app.test.mjs checks SHELL lists every file in public/.

const CACHE = "corkboard-v1";
const SHELL = [
  "./",
  "css/corkboard.css",
  "fonts/marcellus-latin-ext.woff2",
  "fonts/marcellus-latin.woff2",
  "fonts/ptsansnarrow-400-latin-ext.woff2",
  "fonts/ptsansnarrow-400-latin.woff2",
  "fonts/ptsansnarrow-700-latin-ext.woff2",
  "fonts/ptsansnarrow-700-latin.woff2",
  "icons/apple-touch-icon.png",
  "icons/icon-192.png",
  "icons/icon-512.png",
  "icons/icon-maskable-512.png",
  "icons/icon.svg",
  "index.html",
  "js/app/api.js",
  "js/app/boards.js",
  "js/app/dialogs.js",
  "js/app/dom.js",
  "js/app/links.js",
  "js/app/main.js",
  "js/app/storage.js",
  "js/app/tabs.js",
  "js/core/digest.js",
  "js/core/invite.js",
  "js/core/merge.js",
  "js/core/sanitise.js",
  "js/core/util.js",
  "js/model/formats.js",
  "js/model/text.js",
  "js/model/view.js",
  "manifest.webmanifest",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin || url.pathname.includes("/v1/")) return;
  const key = request.mode === "navigate" ? "./" : request;
  event.respondWith(caches.open(CACHE).then(async (cache) => {
    const cached = await cache.match(key, { ignoreSearch: request.mode === "navigate" });
    const fresh = fetch(request).then((response) => {
      if (response.ok) cache.put(key, response.clone());
      return response;
    });
    if (cached) {
      event.waitUntil(fresh.catch(() => {}));
      return cached;
    }
    return fresh;
  }));
});
