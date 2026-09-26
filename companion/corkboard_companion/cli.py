"""The companion's command line (docs/design.md §7.1).

    corkboard-companion                 first run: the setup wizard; after that: watch
    corkboard-companion setup [--api URL] [--wow PATH] [--product FOLDER]
    corkboard-companion status          what it found and when each board last synced
    corkboard-companion sync            sync once
    corkboard-companion watch           sync whenever WoW writes SavedVariables, and every 10 min
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from . import __version__, discover, sync
from .api import Api, ApiError
from .config import Config, State
from .process import wow_running

POLL = 5  # seconds between SavedVariables checks
SETTLE = 3  # seconds to let the client finish writing before reading


def say(text: str) -> None:
    print(text, flush=True)


def find_install(config: Config) -> discover.Install | None:
    roots = [Path(config.wow_root)] if config.wow_root else None
    return discover.find(roots, config.product or None)


def setup(config: Config, args, interactive: bool) -> int:
    if args.api:
        config.api_url = args.api
    if args.wow:
        config.wow_root = args.wow
    if args.product:
        config.product = args.product
    if interactive and not config.api_url:
        config.api_url = input("Sync API address (for example https://corkboard.example.com): ").strip()
    roots = [Path(config.wow_root)] if config.wow_root else discover.default_roots()
    candidates = [i for root in roots for i in discover.installs(root)]
    with_addon = [i for i in candidates if i.has_corkboard]
    if not with_addon and interactive:
        typed = input("Couldn't find World of Warcraft with Corkboard installed. Its folder: ").strip()
        if typed:
            config.wow_root = typed
            with_addon = [i for i in discover.installs(Path(typed)) if i.has_corkboard]
    if len(with_addon) > 1 and interactive and not config.product:
        say("Corkboard is installed in more than one game version:")
        for n, install in enumerate(with_addon, 1):
            say(f"  {n}. {install.product} ({install.flavour or 'unknown flavour'})")
        choice = input(f"Which is WoW: Forever? [1-{len(with_addon)}] ").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(with_addon):
            config.product = str(with_addon[int(choice) - 1].product)
    config.save()
    install = find_install(config)
    if install is None:
        say("No install with Corkboard found. Install the addon, or run setup --wow <folder>.")
        return 1
    if install.symlinked:
        say("Warning: Corkboard is symlinked into AddOns. The client never reads its SavedVariables back (§2).")
    say(f"Using {install.product} ({install.flavour or 'unknown flavour'}).")
    say(f"Sync API: {config.api_url or 'not set'}")
    return 0


def status(config: Config) -> int:
    install = find_install(config)
    say(f"Corkboard companion {__version__}")
    say(f"Sync API: {config.api_url or 'not set'}")
    if install is None:
        say("No install with Corkboard found.")
        return 1
    say(f"Install: {install.product} ({install.flavour or 'unknown flavour'})")
    say(f"SavedVariables: {len(install.saved_variables())} account(s)")
    state = State()
    for board_id, local in sorted(sync.read_boards(install).items()):
        st = state.boards.get(board_id)
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(st.synced_at)) if st and st.synced_at else "never"
        flag = " (secret refused: rejoin)" if st and st.auth_failed else ""
        say(f"  {board_id}: {len(local.board.get('notes', {}))} notes, last synced {when}{flag}")
    return 0


def once(config: Config) -> int:
    install = find_install(config)
    if install is None or not config.api_url:
        say("Not set up yet: run corkboard-companion setup.")
        return 1
    report = sync.run(Api(config.api_url), install, State())
    say(report.line())
    if report.news:
        say("New notes are ready." + (" /reload in game to see them." if wow_running() else ""))
    return 0


def watch(config: Config, stop_after: float | None = None) -> int:
    install = find_install(config)
    if install is None or not config.api_url:
        say("Not set up yet: run corkboard-companion setup.")
        return 1
    api = Api(config.api_url)
    say(f"Watching {install.product}. Press Ctrl+C to stop.")
    seen: dict[Path, float] = {}
    last_run = None
    started = time.monotonic()
    while stop_after is None or time.monotonic() - started < stop_after:
        changed = False
        for path in install.saved_variables():
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            if path in seen and seen[path] != mtime:
                changed = True  # the client wrote it: logout or /reload
            seen[path] = mtime
        due = last_run is None or time.monotonic() - last_run >= config.pull_minutes * 60
        if changed or due:
            if changed:
                time.sleep(SETTLE)
            try:
                report = sync.run(api, install, State())
                say(time.strftime("%H:%M ") + report.line())
                if report.news and wow_running():
                    say("  New notes are ready: /reload in game to see them.")
            except (ApiError, OSError) as e:
                say(time.strftime("%H:%M ") + f"sync failed: {e}")
            last_run = time.monotonic()
        time.sleep(POLL)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="corkboard-companion", description="Syncs Corkboard boards with the cloud.")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="command")
    p = sub.add_parser("setup", help="set the API address and find the game")
    p.add_argument("--api")
    p.add_argument("--wow", help="the World of Warcraft folder")
    p.add_argument("--product", help="the product folder to use, e.g. _classic_beta_")
    sub.add_parser("status")
    sub.add_parser("sync")
    sub.add_parser("watch")
    args = parser.parse_args(argv)
    config = Config.load()
    try:
        if args.command == "setup":
            return setup(config, args, interactive=sys.stdin.isatty())
        if args.command == "status":
            return status(config)
        if args.command == "sync":
            return once(config)
        if args.command == "watch":
            return watch(config)
        if not config.api_url:
            code = setup(config, argparse.Namespace(api=None, wow=None, product=None), interactive=True)
            if code:
                return code
        return watch(config)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
