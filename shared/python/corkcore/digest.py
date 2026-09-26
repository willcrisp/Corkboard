"""Bucketed board digests (docs/design.md §4.4, Core/Digest.lua)."""

from __future__ import annotations

from typing import Iterable

from .util import format_int, fnv1a32, to_bytes, uint32be

BUCKETS = 32


def bucket(note_id: str) -> int:
    return fnv1a32(note_id) % BUCKETS


def line(note: dict) -> str:
    return f"{note['id']}={format_int(note['rev'])};{note['editor']}\n"


def combine(buckets: list[int]) -> int:
    return fnv1a32(b"".join(uint32be(h) for h in buckets))


def compute(notes: Iterable[dict] | dict) -> dict:
    """{digest, buckets, count}; count includes tombstones."""
    if isinstance(notes, dict):
        notes = notes.values()
    lines: list[list[bytes]] = [[] for _ in range(BUCKETS)]
    count = 0
    for note in notes:
        lines[bucket(note["id"])].append(to_bytes(line(note)))
        count += 1
    hashes = [fnv1a32(b"".join(sorted(group))) for group in lines]
    return {"digest": combine(hashes), "buckets": hashes, "count": count}


def mismatched(a: list[int], b: list[int]) -> list[int]:
    return [i for i in range(BUCKETS) if a[i] != b[i]]
