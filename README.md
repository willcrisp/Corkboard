# Corkboard

Shared post-it boards for World of Warcraft: Forever.

Create a board, share it with an invite string, and pin notes with item, quest and spell links for your group. Boards sync between members in game, and an optional companion app lets you catch up on notes even when nobody else is online.

**Status:** design phase. See [`docs/design.md`](docs/design.md) for the spec and phase plan, and [`docs/ui-style.md`](docs/ui-style.md) for the in-game look.

## Components

- `addon/`: the in-game addon (`Corkboard`) and its cloud data addon (`Corkboard_Cloud`)
- `companion/`: desktop app that syncs boards with the cloud when you're offline
- `api/`: self-hosted sync API
- `infra/`: Docker Compose deployment
