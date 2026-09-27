"""Settings. The environment sets the database path and the trusted proxy
(infra/compose.yaml), and CORK_WEB for a local run that also serves the web
app; tests pass the limits directly."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    db: str = "corkboard.db"
    max_body: int = 65536  # bytes per request
    max_notes: int = 1000  # note rows per board, tombstones included
    board_rate: int = 60  # requests per minute per board
    register_rate: int = 20  # board registrations per hour per IP
    page: int = 500  # notes per sync response
    trusted_proxy: str | None = None  # a host whose X-Forwarded-For we believe
    web: str | None = None  # a folder to serve at / (the web app, for local runs; Caddy serves it when deployed)

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        return cls(db=env.get("CORK_DB", cls.db), trusted_proxy=env.get("CORK_TRUSTED_PROXY") or None,
                   web=env.get("CORK_WEB") or None)
