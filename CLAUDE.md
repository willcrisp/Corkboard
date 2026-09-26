# Corkboard

Shared post-it boards for **World of Warcraft: Forever** (client 1.60.x, TOC `## Interface: 16001`).
Players create a board, share it with an invite string, and everyone on it can add free-text notes with item, quest and spell links.
Boards sync peer-to-peer in game over addon messages. A companion app and a self-hosted sync API let members catch up when nobody else is online.

The full spec is in `docs/design.md`. Read it before changing behaviour. Section numbers below (§) refer to it.

Current status and the ordered next steps are in `docs/next-steps.md`. Read it at the start of a session and update it before you finish.

## Repo layout

| Path | What lives here |
|---|---|
| `addon/Corkboard/` | The in-game addon (Lua 5.1, Ace3). The pure merge core is in `Core/`. |
| `addon/spec/` | busted specs for the merge core. Kept outside the addon folder so they never ship. |
| `addon/Corkboard_Cloud/` | Tiny data-only addon. The companion writes its `Data.lua`. Never hand-edit it. |
| `companion/` | Desktop companion (Python 3.12, PyInstaller). Reads SavedVariables and talks to the API. |
| `api/` | Sync API (FastAPI + SQLite). |
| `spikes/` | Throwaway Phase 0 spike addons (not shipped). They may break the hard rules below on purpose, for example by calling `SendAddonMessage` directly. |
| `infra/` | Docker Compose + Caddy for Will's Arcane host, public DNS `corkboard.<domain>`. |
| `tools/` | Release helpers: `package_addon.py` builds the addon zip. |
| `shared/test-vectors/` | JSON fixtures run by both the Lua and Python test suites. |
| `shared/python/` | `corkcore`, the Python port of the merge core, installed by both `api/` and `companion/`. |
| `docs/design.md` | Spec v0.2: architecture, protocol, phases and acceptance criteria. |
| `docs/ui-style.md` | In-game UI look (Blizzard templates, colours, fonts). |
| `docs/mockups/` | Design-canvas sources for the UI mockups (reference only; they need the canvas runtime to render). |
| `.claude/skills/` | Claude Code project skills. `ponytail*` is vendored unchanged from DietrichGebert/ponytail v4.10.0 (MIT); re-copy from upstream to update. |

## How we work

- **Spec-driven, phase-gated.** Work one phase at a time (§12). A phase is done when every acceptance criterion is ticked, with evidence (test output, a screenshot, or a written spike result).
- **Phase 0 comes first.** Its spikes answer questions about the Forever client that the rest of the design depends on. Record answers in `docs/spikes/NN-topic.md`, and update `docs/design.md` if an answer changes the design.
- **Spec changes go in the spec.** If implementation shows the design is wrong, update `docs/design.md` in the same change and say why in the commit message.
- Keep changes small and reviewable. One phase or sub-feature per branch or PR.

## Hard rules

- **Target the modern API.** Forever is vanilla content on a Mainline-style client: use `C_ChatInfo.*` and other `C_*` namespaces, not 1.12 or Classic Era APIs. Lua is 5.1.
- **The merge core is pure Lua.** `Merge`, `Digest` and `Sanitise` must not touch any WoW API, so they run under `busted` outside the game. The Python copies in `companion/` and `api/` must pass the same `shared/test-vectors/`.
- **Merge semantics are fixed** (§4.3): LWW on `(rev, editor)`, tombstones for deletes, HLC-lite clock. Any change needs new test vectors plus property tests.
- **Never send secret values.** Drop any received payload where `issecretvalue(msg)` is true (§2).
- **Respect the send gate and throttle** (§5.5, §5.6). Every send goes through the outbox. Never call `SendAddonMessage` directly from feature code.
- **The companion never writes SavedVariables.** It only writes `addon/Corkboard_Cloud/Data.lua`, atomically (temp file + rename).
- **Sanitise identically** in Lua and Python (§6). A note that fails sanitisation is dropped, not repaired.
- **Hooks:** use `hooksecurefunc` post-hooks only. No pre-hooks or global overrides.
- **UI:** use Blizzard frame templates and follow `docs/ui-style.md`. No custom coloured chrome.

## Testing

- **Lua:** `busted` over `addon/Corkboard/Core/` (merge, digest, sanitiser) plus the shared vectors.
- **Python:** `pytest` in `api/` and `companion/`, with Hypothesis property tests for convergence (§11).
- **In game:** test persistence with `/reload`. A beta bug means SavedVariables don't load on a fresh launch. Copy the addon into the client's `Interface/AddOns`; don't symlink it, or SavedVariables are never read back.
- Dev installs live under the beta folder (`_classic_beta_`) until launch on 2026-11-04.

## Deployment

The API ships as a container from GHCR and runs as an Arcane project on Will's host (`infra/`). Only `corkboard.<domain>` on port 443 (and 80 for ACME) is public. The Arcane dashboard stays tailnet-only.

## Commands

Add commands here as they're created (lint, test, package, run API locally).

Run these from the repo root. They need Lua 5.1 with busted, luacheck, dkjson and luacov: `luarocks --lua-version=5.1 install busted luacheck dkjson luacov`, or on Ubuntu `apt install lua5.1 lua-busted lua-check lua-dkjson` plus `luacov` from luarocks.

- **Test:** `busted` runs every spec, including the property tests.
- **Coverage:** `busted --run=coverage && luacov` writes `luacov.report.out`. This run leaves out the property tests, which are too slow under the coverage hook.
- **Lint:** `luacheck .`
- **Python core:** `pip install -e shared/python && pytest shared/python` runs the shared vectors and the Hypothesis property tests.
- **Fuzz corpus:** `python3 shared/test-vectors/tools/gen_sanitise_fuzz.py` regenerates `sanitise_fuzz.json` after a sanitiser change.
- **Package the addon:** `python3 tools/package_addon.py --version X.Y.Z` writes `dist/Corkboard-X.Y.Z.zip` (Corkboard + Corkboard_Cloud with an empty `Data.lua`).
- **Run the API locally:** `pip install -e shared/python -e api && CORK_DB=/tmp/cork.db python3 -m corkboard_api.app` (port 8000).
- **Companion:** `pip install -e shared/python -e companion && corkboard-companion setup --api URL --wow PATH`, then `corkboard-companion watch`.
- **Spike smoke tests:** `lua5.1 spikes/mock/smoke.lua spikes/CorkSpike/CorkSpike.lua` runs CorkSpike against a fake client, and `lua5.1 spikes/mock/smoke2.lua spikes/CorkSpike2/CorkSpike2.lua` does the same for CorkSpike2.
