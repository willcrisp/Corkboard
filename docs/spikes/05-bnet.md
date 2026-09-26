# 05: `BNSendGameData` on Forever

**Status:** not run yet. The tooling is ready in `spikes/CorkSpike2/` (and `/cspike bnet` in `spikes/CorkSpike/` adds BNet to the shared-budget runs).

## Question

- Does `BNSendGameData` (or `C_BattleNet.SendGameData`) work between two Forever clients?
- What is the largest payload it accepts, and what happens above it (error, result code, silent truncation)?
- What are its burst and sustained rate, and does it share the addon-message budget (spike 02)?
- Do payloads arrive intact and in order?

## How it was tested

- Client build, realm, date:
- Two Battle.net friends, both running CorkSpike2, both online in Forever.
- Steps:
  1. On the sender: `/cspike2 bnet` lists friends; `/cspike2 bnet <gameAccountID>` picks one.
  2. `/cspike2 bnetsize`, then `/cspike2 bnetrate 1000` (about 90 s).
  3. `/cspike2 report` on both clients. The receiver's report has the arrivals.

## Result

_Paste the "Spike 05" part of both reports here._

| Measure | Value |
|---|---|
| Largest accepted payload | |
| Above the limit | |
| Burst | |
| Sustained rate | |
| Shares the addon-message budget? | |

## Design impact

_For example: whether BNet becomes the preferred bulk P2P route (§5.1), and its chunk size in the transport._
