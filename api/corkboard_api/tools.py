"""Offline tools for the database file.

    python3 -m corkboard_api.tools digest corkboard.db   every board's digest, count and cursor

Used by the restore drill (infra/README.md): a restored snapshot's digests
must match the live server's as of the snapshot.
"""

from __future__ import annotations

import sys

from .db import Database


def digest(path: str) -> list[str]:
    db = Database(path)
    try:
        lines = []
        for board_id in db.board_ids():
            d = db.digest(board_id)
            lines.append(f"{board_id} digest={d['digest']:08x} notes={d['count']} cursor={d['cursor']}")
        return lines
    finally:
        db.close()


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] != "digest":
        print(__doc__.strip(), file=sys.stderr)
        return 2
    for line in digest(argv[2]):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
