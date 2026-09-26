"""The sanitiser (docs/design.md §6, Core/Sanitise.lua): a yes/no check, never
a repair. shared/test-vectors/sanitise.json pins the behaviour and reasons."""

from __future__ import annotations

import re

from .util import INT_MAX, byte_len, is_integer, is_utf8

MAX_TEXT = 2000
MAX_NAME = 64
MAX_BOARD_NAME = 64
MAX_ID = 18
COLOR_MAX = 8

LINK_TYPES = frozenset({
    "item", "quest", "spell", "achievement", "currency", "mount", "battlepet", "journal",
    "enchant", "trade",  # a profession recipe and a whole profession (§9.2)
})
# Note kinds (§4.2): no kind is an ordinary note, "gear" a gear-feed entry (§9.1),
# "recipes" a character's recipe list for one profession (§9.2) and "quests" a
# character's quest log (§9.3).
KINDS = frozenset({"gear", "recipes", "quests"})

_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_TEXT_CONTROL = re.compile(r"[\x00-\x09\x0b-\x1f\x7f]")
_HEX8 = re.compile(r"[0-9A-Fa-f]{8}")
_NAMED_COLOUR = re.compile(r"n[0-9A-Za-z_]+:")
_LINK_TYPE = re.compile(r"([^:|]*):")
_LINK_REST = re.compile(r"[^|]*\|h[^|]*\|h")
_NOTE_ID = re.compile(r"[0-9a-f]{8}-[0-9]+\Z")
# Lua's %S in the C locale: anything but space, \t, \n, \v, \f and \r.
_NON_SPACE = re.compile(r"[^ \t\n\v\f\r]")
_NAME = re.compile(r"[^-]+-.", re.DOTALL)


def _check_escapes(s: str) -> tuple[bool, str | None]:
    pos = 0
    while True:
        p = s.find("|", pos)
        if p < 0:
            return True, None
        c = s[p + 1 : p + 2]
        if c in ("|", "r"):
            pos = p + 2
        elif c == "c":
            if _HEX8.match(s, p + 2):
                pos = p + 10
            else:
                m = _NAMED_COLOUR.match(s, p + 2)
                if not m:
                    return False, "escape"
                pos = m.end()
        elif c == "H":
            m = _LINK_TYPE.match(s, p + 2)
            if not m:
                return False, "link"
            if m.group(1) not in LINK_TYPES:
                return False, "link_type"
            m2 = _LINK_REST.match(s, m.end())
            if not m2:
                return False, "link"
            pos = m2.end()
        else:
            return False, "escape"


def text(s: object) -> tuple[bool, str | None]:
    """Note text: (True, None) or (False, reason). Reasons in order: text,
    too_long, utf8, control, then escape, link or link_type left to right."""
    if not isinstance(s, str):
        return False, "text"
    if byte_len(s) > MAX_TEXT:
        return False, "too_long"
    if not is_utf8(s):
        return False, "utf8"
    if _TEXT_CONTROL.search(s):
        return False, "control"
    return _check_escapes(s)


def name(s: object) -> bool:
    """A character name, "Name-Realm"."""
    return (
        isinstance(s, str)
        and byte_len(s) <= MAX_NAME
        and _NAME.match(s) is not None
        and "|" not in s
        and not _CONTROL.search(s)
        and is_utf8(s)
    )


def board_name(s: object) -> bool:
    return (
        isinstance(s, str)
        and byte_len(s) <= MAX_BOARD_NAME
        and _NON_SPACE.search(s) is not None
        and "|" not in s
        and not _CONTROL.search(s)
        and is_utf8(s)
    )


def note_id(s: object) -> bool:
    return isinstance(s, str) and byte_len(s) <= MAX_ID and _NOTE_ID.match(s) is not None


def _int(n: int | float) -> int:
    return int(n)


def note(t: object) -> tuple[dict | None, str | None]:
    """A clean copy with only the known fields, or (None, reason)."""
    if not isinstance(t, dict):
        return None, "type"
    if not note_id(t.get("id")):
        return None, "id"
    if not name(t.get("author")):
        return None, "author"
    if not is_integer(t.get("created"), 0, INT_MAX):
        return None, "created"
    if not is_integer(t.get("rev"), 1, INT_MAX):
        return None, "rev"
    if not name(t.get("editor")):
        return None, "editor"
    if not is_integer(t.get("color"), 1, COLOR_MAX):
        return None, "color"
    if not isinstance(t.get("deleted"), bool):
        return None, "deleted"
    kind = t.get("kind")
    if kind is not None and not (isinstance(kind, str) and kind in KINDS):
        return None, "kind"
    ok, reason = text(t.get("text"))
    if not ok:
        return None, reason
    if t["deleted"] and t["text"] != "":
        return None, "tombstone_text"
    clean = {
        "id": t["id"],
        "author": t["author"],
        "created": _int(t["created"]),
        "rev": _int(t["rev"]),
        "editor": t["editor"],
        "text": t["text"],
        "color": _int(t["color"]),
        "deleted": t["deleted"],
    }
    if kind is not None:
        clean["kind"] = kind
    return clean, None


def member(t: object) -> tuple[dict | None, str | None]:
    if not isinstance(t, dict):
        return None, "type"
    if not name(t.get("name")):
        return None, "name"
    if t.get("role") not in ("owner", "member"):
        return None, "role"
    if not is_integer(t.get("rev"), 1, INT_MAX):
        return None, "rev"
    if not name(t.get("editor")):
        return None, "editor"
    if not isinstance(t.get("removed"), bool):
        return None, "removed"
    return {
        "name": t["name"],
        "role": t["role"],
        "rev": _int(t["rev"]),
        "editor": t["editor"],
        "removed": t["removed"],
    }, None


def meta(t: object) -> tuple[dict | None, str | None]:
    if not isinstance(t, dict):
        return None, "type"
    if not board_name(t.get("name")):
        return None, "name"
    if not is_integer(t.get("rev"), 1, INT_MAX):
        return None, "rev"
    if not name(t.get("editor")):
        return None, "editor"
    return {"name": t["name"], "rev": _int(t["rev"]), "editor": t["editor"]}, None
