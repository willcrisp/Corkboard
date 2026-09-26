"""Whether the game is running: cloud data only appears after the next /reload (§7.1)."""

from __future__ import annotations

import subprocess
import sys

NAMES = ("wow.exe", "wowclassic.exe", "wowclassict.exe", "wowclassicb.exe", "world of warcraft", "wow")


def wow_running() -> bool:
    try:
        if sys.platform == "win32":
            out = subprocess.run(["tasklist", "/fo", "csv", "/nh"], capture_output=True, text=True, timeout=10).stdout
            names = [line.split(",")[0].strip('"').lower() for line in out.splitlines() if line]
        else:
            out = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, timeout=10).stdout
            names = [line.strip().rsplit("/", 1)[-1].lower() for line in out.splitlines()]
    except (OSError, subprocess.SubprocessError):
        return False
    return any(name.startswith(NAMES[:4]) or name in NAMES[4:] for name in names)
