# 06: SavedVariables fresh-launch bug and install discovery

**Status:** not run yet. The tooling is ready: `spikes/CorkSpike2/` (in game) and `spikes/install_probe.py` (desktop).

## Question

- Is the beta bug still there: SavedVariables written at logout but not loaded on a fresh client launch? Does `/reload` still load them?
- What does the client call itself: `WOW_PROJECT_ID` and the other `WOW_PROJECT_*` constants, build and TOC?
- On disk: which product folder does Forever use (`_classic_beta_` now, the live folder after launch), what does its `.flavor.info` say, and which `.build.info` row is it? That's what the companion's install discovery keys on (§7.1).
- Are symlinked addon folders still unable to read their SavedVariables?

## How it was tested

- Client build, date:
- Steps:
  1. Install CorkSpike2 (copy, don't symlink). Log in, `/reload`, then log out to the character screen, exit the game completely, relaunch and log in again. `/cspike2 report`: the "Spike 06" table lists each load.
  2. On the desktop, with the game closed: `python3 spikes/install_probe.py` (or pass the WoW folder as an argument).
  3. Optional: repeat step 1 with a symlinked copy of CorkSpike2.

## Result

_Paste the "Spike 06" part of the report and the whole `install_probe.py` output here._

| Measure | Value |
|---|---|
| SavedVariables load after `/reload` | |
| SavedVariables load after a fresh launch | |
| `WOW_PROJECT_ID` | |
| Product folder | |
| `.flavor.info` | |
| `.build.info` product | |
| Symlinked folders read SavedVariables? | |

## Design impact

_For example: the product and flavour strings in the companion's discovery (`companion/`, §7.1), and whether the §2 beta-bug row can go._
