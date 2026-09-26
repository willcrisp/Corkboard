"""Merge rules (docs/design.md §4.3, Core/Merge.lua): last-writer-wins on
(rev, editor), tombstones for deletes, and the HLC-lite board clock.

A board is a dict with "clock", "notes" (id -> note), "members" (name ->
record) and "meta" (one record or None). Missing fields are created on first
write.
"""

from __future__ import annotations

from typing import Callable, Iterable

from . import sanitise
from .util import compare as compare_bytes


def _cmp(x, y) -> int:
    if x == y:
        return 0
    return -1 if x < y else 1


def compare_version(a: dict, b: dict) -> int:
    c = _cmp(a["rev"], b["rev"])
    if c:
        return c
    return compare_bytes(a["editor"], b["editor"])


def compare_note(a: dict, b: dict) -> int:
    """Total order on two versions of one note: (rev, editor), then a tombstone
    wins the tie, then the greater text, color, author and created."""
    c = compare_version(a, b)
    if c:
        return c
    c = _cmp(bool(a["deleted"]), bool(b["deleted"]))
    if c:
        return c
    c = compare_bytes(a["text"], b["text"])
    if c:
        return c
    c = _cmp(a["color"], b["color"])
    if c:
        return c
    c = compare_bytes(a["author"], b["author"])
    if c:
        return c
    return _cmp(a["created"], b["created"])


def compare_member(a: dict, b: dict) -> int:
    c = compare_version(a, b)
    if c:
        return c
    c = _cmp(bool(a["removed"]), bool(b["removed"]))
    if c:
        return c
    return compare_bytes(a["role"], b["role"])


def compare_meta(a: dict, b: dict) -> int:
    c = compare_version(a, b)
    if c:
        return c
    return compare_bytes(a["name"], b["name"])


# Clock ------------------------------------------------------------------------


def observe(board: dict, rev: int) -> None:
    if rev > board.get("clock", 0):
        board["clock"] = rev


def next_rev(board: dict, now: int) -> int:
    after = board.get("clock", 0) + 1
    return now if now > after else after


# Received records ----------------------------------------------------------------


def _store(board: dict, field: str, key: str, clean: dict, compare: Callable[[dict, dict], int]):
    observe(board, clean["rev"])
    records = board.setdefault(field, {})
    current = records.get(key)
    if current is not None and compare(clean, current) <= 0:
        return False, "stale"
    records[key] = clean
    return True, None


def apply_note(board: dict, note: object) -> tuple[bool, str | None]:
    """Merges one received note: (True, None) if stored, else (False, reason):
    "stale" or the sanitiser's reason."""
    clean, reason = sanitise.note(note)
    if clean is None:
        return False, reason
    return _store(board, "notes", clean["id"], clean, compare_note)


def apply_member(board: dict, member: object) -> tuple[bool, str | None]:
    clean, reason = sanitise.member(member)
    if clean is None:
        return False, reason
    return _store(board, "members", clean["name"], clean, compare_member)


def apply_meta(board: dict, meta: object) -> tuple[bool, str | None]:
    clean, reason = sanitise.meta(meta)
    if clean is None:
        return False, reason
    observe(board, clean["rev"])
    current = board.get("meta")
    if current is not None and compare_meta(clean, current) <= 0:
        return False, "stale"
    board["meta"] = clean
    return True, None


def _apply_all(board, records: Iterable, apply, key):
    stored, dropped = [], []
    for record in records:
        ok, reason = apply(board, record)
        if ok:
            stored.append(record[key])
        elif reason != "stale":
            dropped.append(reason)
    return stored, dropped


def apply_notes(board: dict, notes: Iterable) -> tuple[list, list]:
    return _apply_all(board, notes, apply_note, "id")


def apply_members(board: dict, members: Iterable) -> tuple[list, list]:
    return _apply_all(board, members, apply_member, "name")


# Local changes (the companion and API never make them, but the property tests do) --


def _commit(board, field, key, record, check):
    clean, reason = check(record)
    if clean is None:
        return None, reason
    observe(board, clean["rev"])
    board.setdefault(field, {})[clean[key]] = clean
    return clean, None


def create_note(board: dict, fields: dict, now: int):
    if fields["id"] in board.get("notes", {}):
        return None, "exists"
    return _commit(board, "notes", "id", {
        "id": fields["id"], "author": fields["author"], "created": now, "rev": next_rev(board, now),
        "editor": fields["author"], "text": fields["text"], "color": fields.get("color", 1), "deleted": False,
    }, sanitise.note)


def _current(board, note_id):
    note = board.get("notes", {}).get(note_id)
    if note is None:
        return None, "missing"
    if note["deleted"]:
        return None, "deleted"
    return note, None


def edit_note(board: dict, note_id: str, changes: dict, editor: str, now: int):
    note, reason = _current(board, note_id)
    if note is None:
        return None, reason
    return _commit(board, "notes", "id", {
        "id": note_id, "author": note["author"], "created": note["created"], "rev": next_rev(board, now),
        "editor": editor, "text": changes.get("text", note["text"]), "color": changes.get("color", note["color"]),
        "deleted": False,
    }, sanitise.note)


def delete_note(board: dict, note_id: str, editor: str, now: int):
    note, reason = _current(board, note_id)
    if note is None:
        return None, reason
    return _commit(board, "notes", "id", {
        "id": note_id, "author": note["author"], "created": note["created"], "rev": next_rev(board, now),
        "editor": editor, "text": "", "color": note["color"], "deleted": True,
    }, sanitise.note)


def set_member(board: dict, name: str, role: str, removed: bool, editor: str, now: int):
    return _commit(board, "members", "name", {
        "name": name, "role": role, "rev": next_rev(board, now), "editor": editor, "removed": removed,
    }, sanitise.member)


def set_meta(board: dict, name: str, editor: str, now: int):
    clean, reason = sanitise.meta({"name": name, "rev": next_rev(board, now), "editor": editor})
    if clean is None:
        return None, reason
    observe(board, clean["rev"])
    board["meta"] = clean
    return clean, None
