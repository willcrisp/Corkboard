"""SQLite storage and the server-side merge (docs/design.md §7.3).

Every accepted record gets seq = ++boards.seq, so a client's cursor is simply
the highest seq it has seen. Merging uses corkcore, the same rules as the
addon, so an older or equal record never replaces a newer one.
"""

from __future__ import annotations

import hashlib
import hmac
import sqlite3
import threading
import time
from typing import Any

from corkcore import digest, merge, sanitise

SCHEMA = """
CREATE TABLE IF NOT EXISTS boards (
    id TEXT PRIMARY KEY,
    secret_hash BLOB NOT NULL,
    created_at INTEGER NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0,
    name TEXT, name_rev INTEGER, name_editor TEXT, name_seq INTEGER
);
CREATE TABLE IF NOT EXISTS notes (
    board_id TEXT NOT NULL, note_id TEXT NOT NULL, author TEXT NOT NULL, created INTEGER NOT NULL,
    rev INTEGER NOT NULL, editor TEXT NOT NULL, text TEXT NOT NULL, color INTEGER NOT NULL,
    deleted INTEGER NOT NULL, seq INTEGER NOT NULL,
    PRIMARY KEY (board_id, note_id)
);
CREATE TABLE IF NOT EXISTS members (
    board_id TEXT NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL, rev INTEGER NOT NULL,
    editor TEXT NOT NULL, removed INTEGER NOT NULL, seq INTEGER NOT NULL,
    PRIMARY KEY (board_id, name)
);
CREATE INDEX IF NOT EXISTS notes_seq ON notes(board_id, seq);
CREATE INDEX IF NOT EXISTS members_seq ON members(board_id, seq);
"""


def hash_secret(secret: str) -> bytes:
    return hashlib.sha256(secret.encode("utf-8")).digest()


def _note_row(row: sqlite3.Row) -> dict:
    return {
        "id": row["note_id"], "author": row["author"], "created": row["created"], "rev": row["rev"],
        "editor": row["editor"], "text": row["text"], "color": row["color"], "deleted": bool(row["deleted"]),
    }


def _member_row(row: sqlite3.Row) -> dict:
    return {"name": row["name"], "role": row["role"], "rev": row["rev"], "editor": row["editor"],
            "removed": bool(row["removed"])}


class Database:
    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA synchronous=NORMAL")
        self.conn.executescript(SCHEMA)

    def close(self) -> None:
        self.conn.close()

    def healthy(self) -> bool:
        with self.lock:
            return self.conn.execute("SELECT 1").fetchone()[0] == 1

    # Boards ---------------------------------------------------------------------

    def register(self, board_id: str, secret: str) -> bool:
        """False if the board already exists."""
        with self.lock:
            try:
                self.conn.execute("INSERT INTO boards (id, secret_hash, created_at) VALUES (?, ?, ?)",
                                  (board_id, hash_secret(secret), int(time.time())))
            except sqlite3.IntegrityError:
                return False
        return True

    def check(self, board_id: str, secret: str) -> bool:
        """Constant-time check of a board's secret. Unknown boards fail the same way."""
        with self.lock:
            row = self.conn.execute("SELECT secret_hash FROM boards WHERE id = ?", (board_id,)).fetchone()
        stored = row["secret_hash"] if row else b"\0" * 32
        return hmac.compare_digest(stored, hash_secret(secret)) and row is not None

    def rotate(self, board_id: str, secret: str) -> None:
        with self.lock:
            self.conn.execute("UPDATE boards SET secret_hash = ? WHERE id = ?", (hash_secret(secret), board_id))

    # Sync -----------------------------------------------------------------------

    def sync(self, board_id: str, cursor: int, notes: list, members: list, meta: Any, max_notes: int,
             page: int) -> dict:
        """Merges what the client sent, then returns what changed since its cursor."""
        rejected: list[dict] = []
        with self.lock:
            c = self.conn
            c.execute("BEGIN IMMEDIATE")
            try:
                seq = c.execute("SELECT seq FROM boards WHERE id = ?", (board_id,)).fetchone()["seq"]
                count = c.execute("SELECT COUNT(*) FROM notes WHERE board_id = ?", (board_id,)).fetchone()[0]
                for record in notes:
                    clean, reason = sanitise.note(record)
                    if clean is None:
                        rejected.append({"kind": "note", "id": _key(record, "id"), "reason": reason})
                        continue
                    row = c.execute("SELECT * FROM notes WHERE board_id = ? AND note_id = ?",
                                    (board_id, clean["id"])).fetchone()
                    if row is None:
                        if count >= max_notes:
                            rejected.append({"kind": "note", "id": clean["id"], "reason": "board_full"})
                            continue
                        count += 1
                    elif merge.compare_note(clean, _note_row(row)) <= 0:
                        continue
                    seq += 1
                    c.execute(
                        "INSERT OR REPLACE INTO notes (board_id, note_id, author, created, rev, editor, text, color,"
                        " deleted, seq) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (board_id, clean["id"], clean["author"], clean["created"], clean["rev"], clean["editor"],
                         clean["text"], clean["color"], int(clean["deleted"]), seq))
                for record in members:
                    clean, reason = sanitise.member(record)
                    if clean is None:
                        rejected.append({"kind": "member", "id": _key(record, "name"), "reason": reason})
                        continue
                    row = c.execute("SELECT * FROM members WHERE board_id = ? AND name = ?",
                                    (board_id, clean["name"])).fetchone()
                    if row is not None and merge.compare_member(clean, _member_row(row)) <= 0:
                        continue
                    seq += 1
                    c.execute(
                        "INSERT OR REPLACE INTO members (board_id, name, role, rev, editor, removed, seq)"
                        " VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (board_id, clean["name"], clean["role"], clean["rev"], clean["editor"],
                         int(clean["removed"]), seq))
                if meta is not None:
                    clean, reason = sanitise.meta(meta)
                    if clean is None:
                        rejected.append({"kind": "meta", "id": None, "reason": reason})
                    else:
                        b = c.execute("SELECT name, name_rev, name_editor FROM boards WHERE id = ?",
                                      (board_id,)).fetchone()
                        current = ({"name": b["name"], "rev": b["name_rev"], "editor": b["name_editor"]}
                                   if b["name"] is not None else None)
                        if current is None or merge.compare_meta(clean, current) > 0:
                            seq += 1
                            c.execute("UPDATE boards SET name = ?, name_rev = ?, name_editor = ?, name_seq = ?"
                                      " WHERE id = ?", (clean["name"], clean["rev"], clean["editor"], seq, board_id))
                c.execute("UPDATE boards SET seq = ? WHERE id = ?", (seq, board_id))
                c.execute("COMMIT")
            except BaseException:
                c.execute("ROLLBACK")
                raise
            return self._changes(board_id, cursor, seq, page) | {"rejected": rejected}

    def _changes(self, board_id: str, cursor: int, head: int, page: int) -> dict:
        c = self.conn
        rows = c.execute("SELECT * FROM notes WHERE board_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                         (board_id, cursor, page + 1)).fetchall()
        more = len(rows) > page
        rows = rows[:page]
        upto = rows[-1]["seq"] if more else head
        members = c.execute("SELECT * FROM members WHERE board_id = ? AND seq > ? AND seq <= ? ORDER BY seq",
                            (board_id, cursor, upto)).fetchall()
        b = c.execute("SELECT name, name_rev, name_editor, name_seq FROM boards WHERE id = ?", (board_id,)).fetchone()
        meta = None
        if b["name"] is not None and cursor < b["name_seq"] <= upto:
            meta = {"name": b["name"], "rev": b["name_rev"], "editor": b["name_editor"]}
        return {
            "cursor": upto,
            "more": more,
            "notes": [_note_row(r) for r in rows],
            "members": [_member_row(r) for r in members],
            "meta": meta,
        }

    def digest(self, board_id: str) -> dict:
        with self.lock:
            rows = self.conn.execute("SELECT * FROM notes WHERE board_id = ?", (board_id,)).fetchall()
            seq = self.conn.execute("SELECT seq FROM boards WHERE id = ?", (board_id,)).fetchone()["seq"]
        result = digest.compute([_note_row(r) for r in rows])
        return {"digest": result["digest"], "count": result["count"], "cursor": seq}

    def board_ids(self) -> list[str]:
        with self.lock:
            return [r["id"] for r in self.conn.execute("SELECT id FROM boards ORDER BY id")]


def _key(record: Any, field: str):
    value = record.get(field) if isinstance(record, dict) else None
    return value if isinstance(value, str) else None
