# CorkSpike2

A throwaway addon for Phase 0 spikes 03 to 06 in `docs/spikes/`. It never ships, and Corkboard never loads it. Like CorkSpike, it calls `C_ChatInfo.SendAddonMessage` and `BNSendGameData` directly, on purpose; Corkboard must never do that (§5.5, §5.6).

It has only been smoke-tested against the mocked client (`lua5.1 spikes/mock/smoke2.lua spikes/CorkSpike2/CorkSpike2.lua`). The first real run is in the beta.

| Spike | Command | What it answers |
|---|---|---|
| 03 | `/cspike2 limit` | How many custom channels one character can join, and the notices the client gives. |
| 03 | `/cspike2 reach <name> <password>` (and `reach off`) | Joins a password channel, hides it from every chat frame, and pings it every 5 s. Run it on characters on the same, a connected and an unconnected realm; each report lists whose pings arrived. Also records which hiding function worked and whether the channel still shows anywhere. |
| 04 | `/cspike2 capture`, then `/cspike2 links` | Records links you shift-click for 2 minutes, and which inserter fired (`ChatFrameUtil.InsertLink` or `ChatEdit_InsertLink`, chat box open or not). Then checks each link, plus some the client can build itself: its raw form, Corkboard's sanitiser verdict, the tooltip, and the LibSerialize + LibDeflate round trip, locally and through a whisper to yourself. |
| 05 | `/cspike2 bnet [gameAccountID]`, `bnetsize`, `bnetrate [bytes]` | `BNSendGameData` payload sizes up to 8,000 bytes, then a 40-message burst and a 30 s rate run. The receiving friend also runs CorkSpike2; their report counts arrivals. |
| 06 | automatic, then `/cspike2 report` | Every load records whether SavedVariables were found and whether it was a fresh login or a `/reload`. Plus the build, `WOW_PROJECT_*`, region and portal. |

## Install

1. Copy the `CorkSpike2` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/`. Copy it; don't symlink it.
2. For spike 04, also install Corkboard (`addon/Corkboard`) and enable both. CorkSpike2 borrows Corkboard's LibSerialize, LibDeflate and sanitiser. Without Corkboard, the link checks still record raw links and tooltips, but skip the sanitiser and the round trip.
3. The step-by-step runs are in each spike file: `docs/spikes/03-channels.md`, `04-link-roundtrip.md`, `05-bnet.md` and `06-install-and-sv.md`.

## Reading the report

`/cspike2 report` opens a copyable Markdown report with a section per spike. Just after a `/reload` it shows the previous session. It includes realm names, not your character name. Other characters on a reach test appear as `Name-Realm`, so trim them before pasting if you'd rather not publish them.

## Desktop side of spike 06

`python3 spikes/install_probe.py [WoW folder]` (Python 3.9+, no packages) lists every product folder with its `.flavor.info`, the `.build.info` rows, where Corkboard or the spikes are installed (and whether that's a symlink), and which accounts have their SavedVariables. Account names are replaced by numbers. It only reads.
