# 02: Addon-message throttle

**Status:** not run yet. The tooling is ready in `spikes/CorkSpike/`.

## Question

- What is the per-prefix throttle? That means burst size, sustained rate and refill. §2 assumes about 1 message per second with a small burst, and the §11 simulator assumes a burst of 10.
- Is the budget per prefix, or shared by all of an addon's prefixes?
- Do whisper, channel, guild and BNet share one budget?
- Does message size matter? §5.6 assumes about 255 bytes/s, which only holds if the budget counts messages.
- Are accepted messages ever dropped or reordered on the way?

## How it was tested

- Client build, realm, date:
- Addons loaded besides CorkSpike:
- In a guild / in a group / BNet target:
- Steps: `/cspike all`, then `/cspike report`. See `spikes/CorkSpike/README.md` for how to read each run.

## Result

_Paste the "Spike 02" part of the report here._

| Measure | Value |
|---|---|
| Burst (from a full budget) | |
| Sustained rate, 16-byte messages | |
| Sustained rate, 255-byte messages | |
| Refill after 3 / 6 / 12 s | |
| Separate budget per prefix? | |
| WHISPER shares with CHANNEL / GUILD / PARTY / BNET? | |
| Loss and latency | |

## Design impact

_For example: whether the 8 KB bulk threshold in §5.6 still means about 30 s of budget, the burst to use in the §11 throttle simulator, and whether Corkboard should spread traffic across prefixes or chat types._
