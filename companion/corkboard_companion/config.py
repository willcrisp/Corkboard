"""The companion's own settings and state, in the user's config folder. It
never writes anywhere in the WoW folder except Corkboard_Cloud/Data.lua."""

from __future__ import annotations

import json
import os
import sys
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path


def config_dir() -> Path:
    override = os.environ.get("CORKBOARD_COMPANION_HOME")
    if override:
        return Path(override)
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA", Path.home())) / "Corkboard"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Corkboard"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "corkboard"


def write_atomic(path: Path, data: bytes) -> None:
    """Writes via a temp file in the same folder and a rename, so a reader
    never sees half a file (§7.1)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


@dataclass
class Config:
    api_url: str = ""
    wow_root: str = ""  # empty: search the default places
    product: str = ""  # a product folder chosen once, e.g. "_classic_beta_"
    pull_minutes: int = 10

    @classmethod
    def load(cls, path: Path | None = None) -> "Config":
        path = path or config_dir() / "config.json"
        try:
            data = json.loads(path.read_text("utf-8"))
        except (OSError, ValueError):
            return cls()
        known = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
        return cls(**known)

    def save(self, path: Path | None = None) -> None:
        path = path or config_dir() / "config.json"
        write_atomic(path, json.dumps(asdict(self), indent=2).encode("utf-8"))


@dataclass
class BoardState:
    """What the companion knows about one board on the server."""

    cursor: int = 0
    synced_at: int = 0
    registered: bool = False
    auth_failed: bool = False
    notes: dict = field(default_factory=dict)  # the server's rows, as far as the cursor
    members: dict = field(default_factory=dict)
    meta: dict | None = None


class State:
    def __init__(self, path: Path | None = None):
        self.path = path or config_dir() / "state.json"
        self.boards: dict[str, BoardState] = {}
        try:
            data = json.loads(self.path.read_text("utf-8"))
            for board_id, b in data.get("boards", {}).items():
                known = {k: v for k, v in b.items() if k in BoardState.__dataclass_fields__}
                self.boards[board_id] = BoardState(**known)
        except (OSError, ValueError):
            pass

    def board(self, board_id: str) -> BoardState:
        return self.boards.setdefault(board_id, BoardState())

    def save(self) -> None:
        data = {"version": 1, "boards": {k: asdict(v) for k, v in self.boards.items()}}
        write_atomic(self.path, json.dumps(data, ensure_ascii=False).encode("utf-8", "surrogateescape"))
