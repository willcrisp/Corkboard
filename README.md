# Corkboard

Shared post-it boards for World of Warcraft: Forever.

Create a board, share it with an invite string, and pin notes with item, quest and spell links for your group. Boards sync between members in game, and an optional companion app lets you catch up on notes even when nobody else is online.

**Status:** built through Phase 5 and tested outside the game (busted, pytest, simulations); not yet run in the Forever client. See [`docs/next-steps.md`](docs/next-steps.md) for what's left and what needs checking in game, [`docs/design.md`](docs/design.md) for the spec and phase plan, and [`docs/ui-style.md`](docs/ui-style.md) for the in-game look.

## Components

- `addon/`: the in-game addon (`Corkboard`) and its cloud data addon (`Corkboard_Cloud`)
- `companion/`: desktop app that syncs boards with the cloud when you're offline (`pip install ./shared/python ./companion`, then `corkboard-companion`)
- `api/`: self-hosted sync API (FastAPI + SQLite)
- `shared/`: the test vectors both languages run, and `corkcore`, the Python merge core
- `infra/`: Docker Compose deployment (see `infra/README.md`)
