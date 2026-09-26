#!/usr/bin/env python3
"""Spike 06, desktop side: how can the companion find the Forever install?

Throwaway (Phase 0). Standard library only, Python 3.9+. It never writes
anything. Run it on a machine with the Forever beta installed:

    python3 spikes/install_probe.py                 # default install locations
    python3 spikes/install_probe.py "D:/Games/World of Warcraft"

It prints a Markdown report for docs/spikes/06-install-and-sv.md: every product
folder under the WoW root, its .flavor.info, the matching .build.info rows,
whether Corkboard (or CorkSpike2) is installed there, whether that folder is a
symlink, and which accounts have SavedVariables for them. Account folder names
are replaced by "account 1", "account 2" and so on.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

DEFAULT_ROOTS = [
    Path("C:/Program Files (x86)/World of Warcraft"),
    Path("C:/Program Files/World of Warcraft"),
    Path("/Applications/World of Warcraft"),
    Path.home() / "Games/World of Warcraft",
]

ADDONS = ["Corkboard", "Corkboard_Cloud", "CorkSpike", "CorkSpike2"]


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def parse_build_info(text: str) -> list[dict[str, str]]:
    """.build.info is a pipe-separated table whose header cells look like 'Name!TYPE:size'."""
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        return []
    header = [cell.split("!")[0] for cell in lines[0].split("|")]
    return [dict(zip(header, line.split("|"))) for line in lines[1:]]


def parse_flavor(text: str) -> str:
    """.flavor.info holds a one-column table: a header line, then the flavour."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[1] if len(lines) > 1 else (lines[0] if lines else "")


def probe_root(root: Path, out: list[str]) -> None:
    out.append(f"## WoW root: `{root}`")
    out.append("")
    build_info = read_text(root / ".build.info")
    rows = parse_build_info(build_info) if build_info else []
    if rows:
        out.append("`.build.info` rows:")
        out.append("")
        keep = ["Branch", "Active", "Version", "Product", "Tags"]
        out.append("| " + " | ".join(keep) + " |")
        out.append("|" + "---|" * len(keep))
        for row in rows:
            out.append("| " + " | ".join(row.get(k, "").replace("|", "/")[:60] for k in keep) + " |")
        out.append("")
    else:
        out.append("No `.build.info` at the root.")
        out.append("")

    accounts: dict[str, str] = {}
    out.append("| Product folder | .flavor.info | Interface/AddOns | Addons present (symlink?) | SavedVariables |")
    out.append("|---|---|---|---|---|")
    for folder in sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("_")):
        flavor_text = read_text(folder / ".flavor.info")
        flavor = parse_flavor(flavor_text) if flavor_text is not None else "(none)"
        addons_dir = folder / "Interface" / "AddOns"
        present = []
        for name in ADDONS:
            path = addons_dir / name
            if path.exists():
                present.append(f"{name}{' (symlink)' if path.is_symlink() else ''}")
        saved = []
        account_root = folder / "WTF" / "Account"
        if account_root.is_dir():
            for account in sorted(account_root.iterdir()):
                sv = account / "SavedVariables"
                if not sv.is_dir():
                    continue
                label = accounts.setdefault(account.name, f"account {len(accounts) + 1}")
                for name in ADDONS:
                    file = sv / f"{name}.lua"
                    if file.exists():
                        saved.append(f"{label}: {name}.lua ({file.stat().st_size} B)")
        out.append(
            f"| `{folder.name}` | {flavor} | {'yes' if addons_dir.is_dir() else 'no'} | "
            f"{', '.join(present) or '-'} | {'; '.join(saved) or '-'} |"
        )
    out.append("")
    running = wow_running()
    if running is not None:
        out.append(f"WoW process running: {running}")
        out.append("")


def wow_running() -> str | None:
    """Best effort: the process names the companion would look for."""
    try:
        if os.name == "nt":
            import subprocess

            text = subprocess.run(["tasklist"], capture_output=True, text=True, check=False).stdout
        else:
            import subprocess

            text = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, check=False).stdout
    except OSError:
        return None
    names = sorted({line.strip().split()[0] for line in text.splitlines() if "wow" in line.lower()})
    return ", ".join(names) if names else "no"


def main(argv: list[str]) -> int:
    roots = [Path(a) for a in argv[1:]] or [r for r in DEFAULT_ROOTS if r.is_dir()]
    out = ["# install_probe report", "", f"- Platform: {sys.platform}", ""]
    if not roots:
        out.append("No WoW root found. Pass its path as an argument.")
    for root in roots:
        if root.is_dir():
            probe_root(root, out)
        else:
            out.append(f"`{root}` is not a folder.")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
