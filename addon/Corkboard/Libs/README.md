# Vendored libraries

The libraries from docs/design.md §13, copied unmodified from each project's latest release tag. `luacheck` skips this folder. To update one, replace its files from a newer release and update this table.

| Library | Source | Release | Commit |
|---|---|---|---|
| LibStub, CallbackHandler-1.0, AceAddon-3.0, AceEvent-3.0, AceTimer-3.0, AceDB-3.0, AceConsole-3.0, AceComm-3.0 (with ChatThrottleLib) | github.com/WoWUIDev/Ace3 | `Release-r1403` (2026-08-12) | `d295b12` |
| LibSerialize | github.com/rossnichols/LibSerialize | `v1.2.2` (2026-07-15) | `40d96aa` |
| LibDeflate | github.com/SafeteeWoW/LibDeflate | `1.0.2-release` | `6831edc` |
| LibDataBroker-1.1 | github.com/tekkub/libdatabroker-1-1 | `v1.1.4` (minor 4, unchanged since 2008) | `1a63ede` |

Ace3 r1403 includes the ChatThrottleLib fix for secret values during chat lockdown (WoW 12.x), which matters on Forever's Midnight-style restrictions (§2).

## Not vendored yet

**LibDBIcon-1.0.** Its upstream is the WowAce SVN repository (`repos.wowace.com/wow/libdbicon-1-0`), which the cloud sessions' network policy blocks. The GitHub mirrors are years out of date (the newest is minor 43, from 2019), so they aren't a substitute for a build that loads on modern-API clients. Nothing uses it until the Phase 1 UI adds the minimap button. It needs `LibDBIcon-1.0/LibDBIcon-1.0.lua` and `LibDBIcon-1.0/lib.xml` from a current release.

Licences: Ace3 (`Ace3-LICENSE.txt`, BSD-3-Clause; LibStub is public domain), LibSerialize (`LibSerialize/LICENSE`, MIT), LibDeflate (`LibDeflate/LICENSE.txt`, zlib). LibDataBroker-1.1's repository states no licence; it's embedded by thousands of addons, but check before Phase 6 packaging.
