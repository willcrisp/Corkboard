# Corkboard web app

Your Corkboard boards in a browser: on a desktop, or installed on a phone as an app (PWA). It looks like the in-game window, and syncs through the same API as the desktop companion. The spec is `docs/design.md` §7.4.

## Using it

1. Open `https://corkboard.<domain>/`, the same host as the sync API.
2. Enter a name and paste a board's invite (in game: the **Members** tab, or `/cork invite`). A name without a realm signs your notes `Name-Web`; type `Name-Realm` to post as your character.
3. To install it on a phone: Safari's Share → **Add to Home Screen** on iOS, or Chrome's **Install app** on Android. On a desktop, Chrome and Edge offer **Install** in the address bar.

What you write reaches players in game once a member's companion syncs the board and they `/reload`. Edits made in game reach the app once a companion has pushed them.

## Layout

| Path | What lives here |
|---|---|
| `public/` | Everything the browser loads, served as it is (no build step). |
| `public/js/core/` | The JavaScript port of the merge core: `sanitise`, `merge`, `digest`, `invite`, `util`. Must pass `shared/test-vectors/`. |
| `public/js/model/` | Pure helpers: note text and links (`text.js`), the note kinds the game writes (`formats.js`), labels, ages and identity (`view.js`). |
| `public/js/app/` | The page: `main.js` (window and sync scheduling), `tabs.js`, `dialogs.js` (popups and editors), `links.js`, `boards.js` (the board store and sync), `api.js`, `storage.js` (IndexedDB), `dom.js`. |
| `public/sw.js` | The service worker. Its `SHELL` list must name every file in `public/` (`test/app.test.mjs` checks). |
| `test/` | `node --test` suites: shared vectors and fuzz corpus, merge properties, the model, the board store against a fake API, and the shipped files. |
| `e2e/` | The real API (serving the app via `CORK_WEB`) driven in headless Chromium, desktop and phone. `demo.mjs` pushes a demo board. |
| `tools/` | `render_icons.mjs` re-renders the PNG icons from the SVGs. |

## Running it locally

From the repo root:

```sh
pip install -e shared/python -e api
CORK_DB=/tmp/cork.db CORK_WEB=web/public python3 -m corkboard_api.app   # http://127.0.0.1:8000/
node web/e2e/demo.mjs http://127.0.0.1:8000                             # prints an invite to paste
```

Tests, from `web/`:

```sh
npm ci
npm test        # no browser needed
npm run e2e     # needs the API installed and Playwright's Chromium (npx playwright install chromium)
```
