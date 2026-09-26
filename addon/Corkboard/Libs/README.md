# Vendored libraries

The libraries from docs/design.md §13, copied from each project's latest release tag. `luacheck` skips this folder. To update one, replace its files from a newer release, re-apply the local patches below, and update this table.

## Local patches

The WoW client raises "Division by zero" where plain Lua gives inf or nan, so these never show outside the game. `wire_spec.lua` fails if a re-vendor brings them back.

- **LibSerialize** `_WriterTable.number`: v1.2.2 detects negative zero with `1 / num < 0`, which threw on every envelope holding a `0` (found in game on 2026-09-26). Patched to test `tostring(num)`'s sign. Its float reader's `0.0/0.0` (NaN) is patched to `math_huge - math_huge`. Worth reporting upstream.

| Library | Source | Release | Commit |
|---|---|---|---|
| LibStub, CallbackHandler-1.0, AceDB-3.0, ChatThrottleLib (from `AceComm-3.0/`) | github.com/WoWUIDev/Ace3 | `Release-r1403` (2026-08-12) | `d295b12` |
| LibSerialize | github.com/rossnichols/LibSerialize | `v1.2.2` (2026-07-15) | `40d96aa` |
| LibDeflate | github.com/SafeteeWoW/LibDeflate | `1.0.2-release` | `6831edc` |
| LibDataBroker-1.1 | github.com/tekkub/libdatabroker-1-1 | `v1.1.4` (minor 4, unchanged since 2008) | `1a63ede` |

Only these files from Ace3 are carried: the addon uses its own frame, slash command and `C_Timer` in place of AceAddon, AceConsole, AceEvent and AceTimer, and frames its own messages instead of using AceComm (§5.2). Ace3 r1403 includes the ChatThrottleLib fix for secret values during chat lockdown (WoW 12.x), which matters on Forever's Midnight-style restrictions (§2).

## Not vendored yet

**LibDBIcon-1.0.** Its upstream is the WowAce SVN repository (`repos.wowace.com/wow/libdbicon-1-0`), which the cloud sessions' network policy blocks. The GitHub mirrors are years out of date (the newest is minor 43, from 2019), so they aren't a substitute for a build that loads on modern-API clients. Nothing uses it until the Phase 1 UI adds the minimap button. It needs `LibDBIcon-1.0/LibDBIcon-1.0.lua` and `LibDBIcon-1.0/lib.xml` from a current release.

Licences: Ace3 (`Ace3-LICENSE.txt`, BSD-3-Clause; LibStub is public domain), LibSerialize (`LibSerialize/LICENSE`, MIT), LibDeflate (`LibDeflate/LICENSE.txt`, zlib). LibDataBroker-1.1's repository states no licence; it's embedded by thousands of addons, but check before Phase 6 packaging.
