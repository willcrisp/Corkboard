"""Corkboard's merge core, ported from addon/Corkboard/Core (docs/design.md §4, §6).

It must behave exactly like the Lua: shared/test-vectors pins both. Records are
plain dicts shaped like the Lua tables; strings are str (UTF-8 in Lua).
"""

from . import digest, invite, merge, sanitise, util

__all__ = ["digest", "invite", "merge", "sanitise", "util"]
