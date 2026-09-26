"""The packaged companion's window (docs/design.md §12 Phase 6): a first-run
wizard (API address, WoW folder, which game version), then a small status
window with a log and "Sync now" while the watch loop runs in a thread.

The window itself needs tkinter and a display, so it's untested here; the
choices it offers come from `candidates`, which is. `--cli <command>` runs
the command line instead (cli.py).
"""

from __future__ import annotations

import queue
import sys
import threading
from pathlib import Path

from . import __version__, cli, discover
from .api import Api, ApiError
from .config import Config


def candidates(wow_root: str) -> list[discover.Install]:
    """Game versions with Corkboard installed, best guess for Forever first."""
    roots = [Path(wow_root)] if wow_root else discover.default_roots()
    return [i for root in roots for i in discover.installs(root) if i.has_corkboard]


def label(install: discover.Install) -> str:
    return f"{install.product.name} ({install.flavour or 'unknown flavour'})"


def check_api(url: str) -> str:
    """A sentence for the wizard about whether the API answers."""
    if not url.startswith("https://") and not url.startswith("http://localhost"):
        return "The address should start with https://"
    try:
        return "Connected." if Api(url, timeout=8).health() else "The server answered, but isn't healthy."
    except ApiError as e:
        return f"The server answered {e.status}. Is that the Corkboard address?"
    except OSError as e:
        return f"Couldn't reach it: {e}"


def run_window(config: Config) -> None:  # pragma: no cover - needs a display
    import tkinter as tk
    from tkinter import filedialog, ttk

    root = tk.Tk()
    root.title(f"Corkboard Companion {__version__}")
    root.geometry("560x380")
    frame = ttk.Frame(root, padding=12)
    frame.pack(fill="both", expand=True)
    lines: queue.Queue[str] = queue.Queue()
    stop, wake = threading.Event(), threading.Event()

    def clear():
        for child in frame.winfo_children():
            child.destroy()

    def status_view():
        clear()
        install = cli.find_install(config)
        ttk.Label(frame, text=f"Game: {label(install)}").pack(anchor="w")
        ttk.Label(frame, text=f"Sync API: {config.api_url}").pack(anchor="w")
        log = tk.Text(frame, height=14, state="disabled", wrap="word")
        log.pack(fill="both", expand=True, pady=8)
        buttons = ttk.Frame(frame)
        buttons.pack(fill="x")
        ttk.Button(buttons, text="Sync now", command=wake.set).pack(side="left")
        ttk.Button(buttons, text="Settings", command=lambda: (stop.set(), wizard_view())).pack(side="left", padx=6)

        def pump():
            while not lines.empty():
                log.configure(state="normal")
                log.insert("end", lines.get() + "\n")
                log.see("end")
                log.configure(state="disabled")
            root.after(500, pump)

        stop.clear()
        threading.Thread(target=cli.watch_loop, args=(config, lines.put, stop, wake), daemon=True).start()
        pump()

    def wizard_view():
        clear()
        ttk.Label(frame, text="Set up Corkboard's cloud sync", font=("", 12, "bold")).pack(anchor="w")
        ttk.Label(frame, text="Sync API address (the board owner's server):").pack(anchor="w", pady=(10, 0))
        url = tk.StringVar(value=config.api_url or "https://")
        ttk.Entry(frame, textvariable=url, width=60).pack(fill="x")
        result = ttk.Label(frame, text="")
        ttk.Button(frame, text="Test connection",
                   command=lambda: result.configure(text=check_api(url.get().strip()))).pack(anchor="w", pady=4)
        result.pack(anchor="w")
        ttk.Label(frame, text="World of Warcraft folder:").pack(anchor="w", pady=(10, 0))
        folder = tk.StringVar(value=config.wow_root)
        row = ttk.Frame(frame)
        row.pack(fill="x")
        ttk.Entry(row, textvariable=folder).pack(side="left", fill="x", expand=True)
        ttk.Label(frame, text="Game version with Corkboard:").pack(anchor="w", pady=(10, 0))
        choice = ttk.Combobox(frame, state="readonly", width=50)
        choice.pack(anchor="w")
        found: list[discover.Install] = []

        def refresh(*_):
            found[:] = candidates(folder.get().strip())
            choice["values"] = [label(i) for i in found] or ["Corkboard isn't installed there"]
            choice.current(0)

        def browse():
            picked = filedialog.askdirectory(title="World of Warcraft folder")
            if picked:
                folder.set(picked)
                refresh()

        ttk.Button(row, text="Browse…", command=browse).pack(side="left", padx=6)
        refresh()

        def save():
            if not found:
                result.configure(text="Pick the folder where Corkboard is installed first.")
                return
            config.api_url = url.get().strip()
            config.wow_root = folder.get().strip()
            config.product = str(found[choice.current()].product)
            config.save()
            status_view()

        ttk.Button(frame, text="Save and start", command=save).pack(anchor="e", pady=12)

    if config.api_url and cli.find_install(config):
        status_view()
    else:
        wizard_view()
    root.protocol("WM_DELETE_WINDOW", lambda: (stop.set(), root.destroy()))
    root.mainloop()


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--cli"]:
        return cli.main(argv[1:])
    try:
        run_window(Config.load())
    except ImportError:  # no tkinter: fall back to the command line
        return cli.main(argv)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
