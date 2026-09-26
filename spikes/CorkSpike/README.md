# CorkSpike

A throwaway addon for the Phase 0 spikes in `docs/spikes/`. It never ships, and Corkboard never loads it.

It answers:

- **Spike 01:** what the client's outgoing addon-message restriction check is called, when it's true, and every `SendAddonMessage` result code.
- **Spike 02:** the per-prefix throttle. That means burst size, sustained rate, refill, whether it's per prefix, whether whisper, channel, guild and BNet share one budget, and whether message size matters.

It calls `C_ChatInfo.SendAddonMessage` directly, on purpose, to see what the client does with no queue in between. Corkboard must never do this (§5.5, §5.6).

It has only been smoke-tested against a mocked client outside the game. The first real run is in the beta.

## Install

1. Copy the `CorkSpike` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`. Copy it; don't symlink it, or its SavedVariables are never read back.
2. Disable every other addon for the throttle run. Other addons' traffic could share the budget and skew the numbers. The report lists any other addons that were loaded.

## Run the throttle script (spikes 01 and 02)

1. Log in and stand somewhere quiet. For the GUILD and PARTY comparisons, be in a guild and a group. Otherwise those runs are skipped.
2. Type `/cspike all`. It takes about 6 minutes. It prints progress to chat and waits 30 s before each run that needs a full budget. Don't chat or run other addons meanwhile.
3. Type `/cspike report`. A window opens with the report as Markdown, already selected. Press Ctrl+C and paste it into the Result sections of `docs/spikes/01-send-restriction.md` (the "Spike 01" part) and `docs/spikes/02-throttle.md` (the "Spike 02" part).

What you'll see in game:

- The script joins a hidden, password-protected temporary channel for the CHANNEL runs and leaves it at the end.
- Nearly all messages are whispers to yourself. The result-code cases also send one invisible addon message each to SAY, YELL, GUILD and your group, if you're in one.
- One "No player named …" system message is expected; it comes from a deliberate whisper to a player who doesn't exist.

## Run the restriction canary (spike 01)

1. Run `/cspike probe` first. It lists every function whose name mentions restrict, lockdown or secret, with its current value. If the right check needs an argument, add it as an expression, using names the probe actually listed. For example, if it listed a `C_Example.IsRestricted` function and an `Enum.ExampleRestrictionType` table, you'd type `/cspike watch C_Example.IsRestricted(Enum.ExampleRestrictionType.Chat)`.
2. Type `/cspike canary on`. Every second it polls those functions, and every 2 s it whispers yourself once. Each change is logged with context (combat, dead, encounter, instance type), as is each change in the send result.
3. Do the things that might restrict sends: pull a dungeon boss, wipe, die in the open world, release, run back, resurrect, get combat-resurrected, and accept a resurrect.
4. Type `/cspike canary off`, then `/cspike report`. The canary lines are in the Log section.

## Optional: a second client or a BNet friend

- `/cspike target Name-Realm` sends whisper runs to another character that is also running CorkSpike. That character's report lists what arrived under "Arrivals from other characters". This checks for server-side drops that the result codes can't show.
- `/cspike bnet` lists BNet friends who are online in WoW. `/cspike bnet <gameAccountID>` adds BNet to the shared-budget runs. It also gives a first look at spike 05.

## Commands

| Command | What it does |
|---|---|
| `/cspike all` | The whole script: probe, result codes, then burst, rate, refill, prefix and shared-budget runs. |
| `/cspike report` | Opens the copyable report. Just after a `/reload`, it shows the previous session. |
| `/cspike probe`, `/cspike codes` | Runs only the API probe, or only the result-code cases. |
| `/cspike burst\|rate\|refill\|prefix [TYPE]` | Runs a single measurement. `TYPE` is `WHISPER` (default), `CHANNEL`, `GUILD`, `PARTY`, `RAID` or `BNET`. |
| `/cspike share FROM TO` | Drains `FROM`, then tries `TO` straight away. |
| `/cspike channel [name]` | Joins a temporary channel for CHANNEL runs. |
| `/cspike canary on\|off` | Starts or stops the restriction canary. |
| `/cspike watch <expr>` | Adds a Lua expression for the canary to poll. |
| `/cspike stop` | Aborts the running script and the canary. |

## Reading the report

- **Burst:** "Accepted" for `r1`, the first burst, sent after 30 s of quiet.
- **Sustained rate:** the msg/s line under each `rate` run, counted after the first rejection. The 255-byte rate run shows whether the budget counts messages or bytes.
- **Refill:** what each `refill` burst got after waiting 3, 6 and 12 s on an empty budget.
- **Per prefix:** the `prefix` run tries `CORKSPK2` right after draining `CORKSPK1`. If it was accepted, each prefix has its own budget.
- **Shared budget:** each `share` run tries another chat type right after draining WHISPER. If it was accepted, the two don't share a budget.
- **Loss and latency:** "Received" counts loopback arrivals, so accepted minus received is what the server dropped. Latency is measured from send to arrival.

The report leaves out your character name. It includes the realm name, and other characters show up as `peer1`, `peer2` and so on. The raw data from the last 5 sessions is in `WTF/Account/<account>/SavedVariables/CorkSpike.lua`.
