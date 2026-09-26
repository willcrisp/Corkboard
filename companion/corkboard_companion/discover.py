"""Finding the Forever install (docs/design.md §7.1).

The WoW root holds one folder per product (`_retail_`, `_classic_era_`,
`_classic_beta_`, …), each with a `.flavor.info` naming its flavour. The
companion wants the product folder that has Corkboard installed, preferring
Forever. Forever's live folder and flavour string aren't known until launch
(2026-11-04; spike 06), so the preference is a list of guesses, and a choice
the player makes once is stored in the config.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path

# Guesses, best first, for Forever's flavour (from .flavor.info) and folder.
FOREVER_FLAVOURS = ("wow_forever", "wow_classic_forever", "wow_classic_beta", "wow_classic_ptr")
FOREVER_FOLDERS = ("_forever_", "_classic_forever_", "_classic_beta_", "_classic_ptr_")


def default_roots() -> list[Path]:
    roots = []
    if sys.platform == "win32":
        for env in ("PROGRAMFILES(X86)", "PROGRAMFILES"):
            base = os.environ.get(env)
            if base:
                roots.append(Path(base) / "World of Warcraft")
        roots += [Path("C:/Program Files (x86)/World of Warcraft"), Path("D:/World of Warcraft"),
                  Path("D:/Games/World of Warcraft")]
    elif sys.platform == "darwin":
        roots.append(Path("/Applications/World of Warcraft"))
    roots.append(Path.home() / "Games" / "World of Warcraft")
    seen, out = set(), []
    for root in roots:
        key = str(root).lower()
        if key not in seen:
            seen.add(key)
            out.append(root)
    return out


def read_flavour(folder: Path) -> str | None:
    try:
        lines = [l.strip() for l in (folder / ".flavor.info").read_text("utf-8", "replace").splitlines() if l.strip()]
    except OSError:
        return None
    return lines[-1] if lines else None


@dataclass
class Install:
    product: Path  # e.g. <root>/_classic_beta_
    flavour: str | None
    has_corkboard: bool
    symlinked: bool

    @property
    def addons(self) -> Path:
        return self.product / "Interface" / "AddOns"

    @property
    def cloud_data(self) -> Path:
        return self.addons / "Corkboard_Cloud" / "Data.lua"

    def saved_variables(self) -> list[Path]:
        """Corkboard's SavedVariables in every account folder."""
        accounts = self.product / "WTF" / "Account"
        if not accounts.is_dir():
            return []
        return sorted(p / "SavedVariables" / "Corkboard.lua" for p in accounts.iterdir()
                      if (p / "SavedVariables" / "Corkboard.lua").is_file())

    def score(self) -> tuple:
        flavour = self.flavour or ""
        by_flavour = FOREVER_FLAVOURS.index(flavour) if flavour in FOREVER_FLAVOURS else len(FOREVER_FLAVOURS)
        name = self.product.name
        by_folder = FOREVER_FOLDERS.index(name) if name in FOREVER_FOLDERS else len(FOREVER_FOLDERS)
        return (not self.has_corkboard, by_flavour, by_folder, name)


def installs(root: Path) -> list[Install]:
    """Product folders under a WoW root, best candidate first."""
    if not root.is_dir():
        return []
    out = []
    for folder in root.iterdir():
        if folder.is_dir() and folder.name.startswith("_") and folder.name.endswith("_"):
            addon = folder / "Interface" / "AddOns" / "Corkboard"
            out.append(Install(folder, read_flavour(folder), addon.is_dir(), addon.is_symlink()))
    return sorted(out, key=Install.score)


def find(roots: list[Path] | None = None, product: str | None = None) -> Install | None:
    """The install to use: the configured product folder if given, else the best candidate that has Corkboard."""
    for root in roots or default_roots():
        for install in installs(root):
            if product:
                if str(install.product) == product or install.product.name == product:
                    return install
            elif install.has_corkboard:
                return install
    return None
