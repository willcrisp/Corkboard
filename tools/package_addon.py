#!/usr/bin/env python3
"""Builds the addon zip players install (docs/design.md §12 Phase 6).

    python3 tools/package_addon.py [--version 0.1.0] [--out dist] [--install ADDONS_DIR]

The zip holds two folders, Corkboard and Corkboard_Cloud, ready to unzip into
Interface/AddOns. Corkboard_Cloud gets an empty Data.lua so the client doesn't
log a missing file before the companion's first sync; the companion replaces
it. The version goes into both TOCs in place of "0.1.0-dev".

--install unzips it into a client's Interface/AddOns for in-game testing, as a
copy (a symlinked addon never reads its SavedVariables back). It replaces both
folders but keeps a Data.lua the companion already wrote there.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDONS = ("Corkboard", "Corkboard_Cloud")
EMPTY_DATA = b"-- Written by the Corkboard companion after its first sync. Don't edit.\nCorkboardCloudData = nil\n"
SKIP = re.compile(r"(^|/)(\.[^/]*|__pycache__|.*\.pyc|Data\.lua)$")


def toc_version(text: str) -> str | None:
    m = re.search(r"^## Version: (.+)$", text, re.M)
    return m.group(1).strip() if m else None


def build(version: str | None, out: Path) -> Path:
    base = ROOT / "addon"
    toc = (base / "Corkboard" / "Corkboard.toc").read_text("utf-8")
    version = version or toc_version(toc) or "dev"
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"Corkboard-{version}.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for addon in ADDONS:
            folder = base / addon
            for file in sorted(folder.rglob("*")):
                rel = file.relative_to(base).as_posix()
                if file.is_dir() or SKIP.search(rel) or file.name == "README.md" and addon == "Corkboard_Cloud":
                    continue
                data = file.read_bytes()
                if file.suffix == ".toc":
                    data = re.sub(rb"^## Version: .*$", f"## Version: {version}".encode(), data, flags=re.M)
                z.writestr(rel, data)
        z.writestr("Corkboard_Cloud/Data.lua", EMPTY_DATA)
    return path


def install(path: Path, addons_dir: Path) -> None:
    data = addons_dir / "Corkboard_Cloud" / "Data.lua"
    kept = data.read_bytes() if data.is_file() else None
    for addon in ADDONS:
        shutil.rmtree(addons_dir / addon, ignore_errors=True)
    with zipfile.ZipFile(path) as z:
        z.extractall(addons_dir)
    if kept is not None:
        data.write_bytes(kept)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version")
    parser.add_argument("--out", default=str(ROOT / "dist"))
    parser.add_argument("--install", metavar="ADDONS_DIR", help="also unzip into this Interface/AddOns folder")
    args = parser.parse_args(argv)
    path = build(args.version, Path(args.out))
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
    print(f"{path} ({len(names)} files)")
    if args.install:
        addons_dir = Path(args.install)
        if not addons_dir.is_dir():
            parser.error(f"{addons_dir} is not a folder")
        install(path, addons_dir)
        print(f"Installed into {addons_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
