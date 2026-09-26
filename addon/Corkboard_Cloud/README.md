# Corkboard_Cloud

A data-only addon (docs/design.md §7.1, §7.2). The desktop companion writes `Data.lua`, which sets the global `CorkboardCloudData`, and Corkboard merges it at `PLAYER_LOGIN`. It's a separate addon so that updating Corkboard never wipes the companion's data.

- **Never edit `Data.lua` by hand**, and never commit it (it's in `.gitignore`). The companion rewrites it atomically on every sync.
- The package ships an empty `Data.lua` (`CorkboardCloudData = nil`), made by the packaging step, so the client doesn't log a missing file before the companion's first sync.
- It depends on Corkboard, so it loads after Corkboard and still before `PLAYER_LOGIN`.
