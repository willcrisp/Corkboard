"""Invite strings (docs/design.md §9, Core/Invite.lua): CORK1:<base64(id|secret|owner)>."""

from __future__ import annotations

import base64
import binascii
import re

from . import sanitise

PREFIX = "CORK1:"
_ID = re.compile(r"[0-9a-z]{16}\Z")
_SECRET = re.compile(r"[0-9A-Za-z]{16,64}\Z")
_VERSION = re.compile(r"[Cc][Oo][Rr][Kk]([0-9]+):(.*)\Z", re.DOTALL)
_BASE64 = re.compile(r"[A-Za-z0-9+/]*\Z")


def valid_id(board_id: object) -> bool:
    return isinstance(board_id, str) and _ID.match(board_id) is not None


def valid_secret(secret: object) -> bool:
    return isinstance(secret, str) and _SECRET.match(secret) is not None


def encode(board: dict) -> str:
    raw = f"{board['id']}|{board['secret']}|{board['owner']}".encode("utf-8")
    return PREFIX + base64.b64encode(raw).decode("ascii")


def decode(s: object) -> tuple[dict | None, str | None]:
    if not isinstance(s, str):
        return None, "invite"
    # Lua's %s: space, \t, \n, \v, \f, \r.
    s = s.strip(" \t\n\v\f\r")
    m = _VERSION.match(s)
    if not m:
        return None, "invite"
    if m.group(1) != "1":
        return None, "invite_version"
    body = m.group(2).rstrip("=")
    if len(body) % 4 == 1 or not _BASE64.match(body):
        return None, "invite_corrupt"
    try:
        raw = base64.b64decode(body + "=" * (-len(body) % 4), validate=True)
    except (binascii.Error, ValueError):
        return None, "invite_corrupt"
    text = raw.decode("utf-8", "surrogateescape")
    parts = text.split("|", 2)
    if len(parts) != 3:
        return None, "invite_corrupt"
    board_id, secret, owner = parts
    if not valid_id(board_id) or not valid_secret(secret) or not sanitise.name(owner):
        return None, "invite_corrupt"
    return {"id": board_id, "secret": secret, "owner": owner}, None
