"""Byte-level helpers shared by the merge core (Core/Util.lua)."""

from __future__ import annotations

import math

INT_MAX = 9007199254740991  # 2^53 - 1, the largest integer a Lua number holds exactly

FNV_OFFSET = 2166136261
FNV_PRIME = 16777619


def to_bytes(s: str) -> bytes:
    """A str as the bytes Lua would hold. Lone surrogates (from invalid UTF-8
    decoded with surrogateescape) turn back into the original bytes."""
    return s.encode("utf-8", "surrogateescape")


def compare(a: str, b: str) -> int:
    """Three-way byte-wise compare, -1, 0 or 1, like Util.compare."""
    x, y = to_bytes(a), to_bytes(b)
    if x == y:
        return 0
    return -1 if x < y else 1


def less(a: str, b: str) -> bool:
    return compare(a, b) < 0


def fnv1a32(data: bytes | str) -> int:
    """32-bit FNV-1a."""
    if isinstance(data, str):
        data = to_bytes(data)
    h = FNV_OFFSET
    for byte in data:
        h = ((h ^ byte) * FNV_PRIME) & 0xFFFFFFFF
    return h


def uint32be(n: int) -> bytes:
    return int(n).to_bytes(4, "big")


def is_integer(n: object, lo: int, hi: int) -> bool:
    """A number with no fractional part in [lo, hi]. Booleans aren't numbers
    here, though Python counts them as ints."""
    if isinstance(n, bool) or not isinstance(n, (int, float)):
        return False
    if isinstance(n, float) and (math.isnan(n) or math.isinf(n) or n != int(n)):
        return False
    return lo <= n <= hi


def format_int(n: int | float) -> str:
    """Plain decimal, never exponent form (Util.formatInt)."""
    return str(int(n))


def is_utf8(s: str) -> bool:
    """Strict UTF-8: a str with lone surrogates came from invalid bytes."""
    try:
        s.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def byte_len(s: str) -> int:
    return len(to_bytes(s))
