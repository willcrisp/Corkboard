"""One sync run (docs/design.md §7.1):

1. Read Corkboard's SavedVariables from every account in the install. Boards
   with cloud sync on are synced; the same board in two accounts is merged.
2. For each board, push every record the server doesn't have in that version
   (compared with the companion's copy of the server's rows, which is exact,
   rather than the design's "rev > lastPushedClock", which misses older notes
   that arrive over P2P after a push), then pull what changed since the cursor.
   An unknown board is registered; a refused secret is rotated from one of the
   board's old secrets (§7.3 rotate), since every member's companion only
   knows what its own SavedVariables say.
3. Write AddOns/Corkboard_Cloud/Data.lua with the rows the addon doesn't have
   yet, atomically. The companion never writes SavedVariables.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field

from corkcore import merge

from . import luadata
from .api import Api, ApiError
from .config import BoardState, State, write_atomic
from .discover import Install

REQUEST_BUDGET = 48_000  # bytes of records per request, under the API's 64 KB


@dataclass
class LocalBoard:
    """A board as the SavedVariables hold it, merged across accounts."""

    id: str
    secrets: list[str]  # the current secret first, then older ones
    board: dict  # {"clock", "notes", "members", "meta"} in corkcore's shape


@dataclass
class Report:
    boards: dict = field(default_factory=dict)  # id -> {"pushed", "pulled", "error"}
    wrote: bool = False  # Data.lua was rewritten
    news: bool = False  # ...with notes, members or a name the addon doesn't have yet

    def line(self) -> str:
        parts = []
        for board_id, r in sorted(self.boards.items()):
            if r.get("error"):
                parts.append(f"{board_id}: {r['error']}")
            else:
                parts.append(f"{board_id}: pushed {r['pushed']}, pulled {r['pulled']}")
        return "; ".join(parts) or "no boards with cloud sync on"


def _records(value) -> list:
    if isinstance(value, dict):
        return list(value.values())
    if isinstance(value, list):
        return value
    return []


def read_boards(install: Install) -> dict[str, LocalBoard]:
    boards: dict[str, LocalBoard] = {}
    for path in install.saved_variables():
        try:
            data = luadata.load(path)
        except (OSError, luadata.LuaSyntaxError):
            continue
        db = data.get("CorkboardDB")
        stored = db.get("global", {}).get("boards", {}) if isinstance(db, dict) else {}
        if not isinstance(stored, dict):
            continue
        for board_id, b in stored.items():
            if not isinstance(b, dict) or not isinstance(b.get("secret"), str) or b.get("cloud") is not True:
                continue
            local = boards.get(board_id)
            if local is None:
                local = boards[board_id] = LocalBoard(board_id, [], {"clock": 0})
            for secret in [b["secret"], *_records(b.get("oldSecrets"))]:
                if isinstance(secret, str) and secret not in local.secrets:
                    local.secrets.append(secret)
            merge.apply_notes(local.board, _records(b.get("notes")))
            merge.apply_members(local.board, _records(b.get("members")))
            if b.get("meta") is not None:
                merge.apply_meta(local.board, b["meta"])
    return boards


def _newer(records: list[dict], known: dict, key: str, compare) -> list[dict]:
    """Records (already clean) that beat the server copy's version, or that it lacks."""
    out = []
    for record in records:
        current = known.get(record[key])
        if current is None or compare(record, current) > 0:
            out.append(record)
    return out


def _batches(notes: list[dict]):
    batch, size = [], 0
    for note in notes:
        n = len(json.dumps(note, ensure_ascii=False).encode("utf-8", "surrogateescape"))
        if batch and size + n > REQUEST_BUDGET:
            yield batch
            batch, size = [], 0
        batch.append(note)
        size += n
    yield batch


def _absorb(state: BoardState, response: dict) -> int:
    """Merges the server's rows into the companion's copy. Returns how many changed."""
    board = {"clock": 0, "notes": state.notes, "members": state.members, "meta": state.meta}
    stored, _ = merge.apply_notes(board, response.get("notes", []))
    members, _ = merge.apply_members(board, response.get("members", []))
    if response.get("meta") is not None:
        merge.apply_meta(board, response["meta"])
    state.meta = board.get("meta")
    state.cursor = max(state.cursor, int(response.get("cursor", state.cursor)))
    return len(stored) + len(members)


def _authorise(api: Api, local: LocalBoard, state: BoardState) -> str | None:
    """Returns a secret the server accepts for this board, registering or
    rotating as needed, or None."""
    secret = local.secrets[0]
    try:
        api.register(local.id, secret)
        state.registered = True
        return secret
    except ApiError as e:
        if e.status != 409:
            raise
    for old in local.secrets[1:]:
        try:
            api.rotate(local.id, old, secret)
            return secret
        except ApiError as e:
            if e.status not in (401, 400):
                raise
    return None


def sync_board(api: Api, local: LocalBoard, state: BoardState, now: int) -> dict:
    secret = local.secrets[0]
    pushed = pulled = 0
    notes = _newer(list(local.board.get("notes", {}).values()), state.notes, "id", merge.compare_note)
    members = _newer(list(local.board.get("members", {}).values()), state.members, "name", merge.compare_member)
    meta = local.board.get("meta")
    if meta is not None and state.meta is not None and merge.compare_meta(meta, state.meta) <= 0:
        meta = None
    retried = False
    batches = list(_batches(notes))
    i = 0
    while True:
        batch = batches[i] if i < len(batches) else []
        try:
            response = api.sync(local.id, secret, state.cursor, batch, members, meta)
        except ApiError as e:
            if e.status == 401 and not retried:
                retried = True
                accepted = _authorise(api, local, state)
                if accepted is None:
                    state.auth_failed = True
                    return {"pushed": pushed, "pulled": pulled, "error": "secret refused: rejoin with a new invite"}
                continue
            if e.status == 429:
                return {"pushed": pushed, "pulled": pulled, "error": "rate limited: will retry"}
            raise
        state.auth_failed = False
        pushed += len(batch) + len(members) + (1 if meta else 0)
        members, meta = [], None
        pulled += _absorb(state, response)
        i += 1
        if i >= len(batches) and not response.get("more"):
            break
    state.synced_at = now
    return {"pushed": pushed, "pulled": pulled, "error": None}


def cloud_data(boards: dict[str, LocalBoard], state: State) -> dict:
    """CorkboardCloudData (§7.2): per board, the server rows the addon doesn't have yet."""
    out = {}
    for board_id, local in sorted(boards.items()):
        st = state.boards.get(board_id)
        if st is None or not st.synced_at:
            continue
        have = local.board
        entry = {
            "cursor": st.cursor,
            "syncedAt": st.synced_at,
            "notes": _newer(sorted(st.notes.values(), key=lambda n: n["id"]), have.get("notes", {}), "id",
                            merge.compare_note),
            "members": _newer(sorted(st.members.values(), key=lambda m: m["name"]), have.get("members", {}),
                              "name", merge.compare_member),
        }
        if st.meta is not None and (have.get("meta") is None or merge.compare_meta(st.meta, have["meta"]) > 0):
            entry["meta"] = st.meta
        out[board_id] = entry
    return out


HEADER = ("Written by the Corkboard companion. Don't edit: it's rewritten on every sync.\n"
          "The addon merges it at login (docs/design.md §7.2).")


def write_cloud_data(install: Install, boards: dict, state: State, now: int) -> tuple[bool, bool]:
    """Rewrites Data.lua if anything but its timestamp changed. Returns
    (wrote, news): whether it wrote, and whether the records the addon is
    missing changed (the player then wants to /reload)."""
    data = {"version": 1, "written": now, "boards": cloud_data(boards, state)}
    path = install.cloud_data
    try:
        old = luadata.load(path).get("CorkboardCloudData")
    except (OSError, luadata.LuaSyntaxError):
        old = None

    def records(d):
        return luadata.dumps("X", {k: {f: v for f, v in b.items() if f not in ("cursor", "syncedAt")}
                                   for k, b in (d.get("boards") or {}).items() if isinstance(b, dict)})

    def body(d):
        return luadata.dumps("X", {k: v for k, v in d.items() if k != "written"})

    if isinstance(old, dict) and body(old) == body(data):
        return False, False
    news = not isinstance(old, dict) or records(old) != records(data)
    write_atomic(path, luadata.dumps("CorkboardCloudData", data, HEADER))
    return True, news


def run(api: Api, install: Install, state: State, now: int | None = None) -> Report:
    now = int(time.time()) if now is None else now
    report = Report()
    boards = read_boards(install)
    for board_id, local in boards.items():
        st = state.board(board_id)
        try:
            report.boards[board_id] = sync_board(api, local, st, now)
        except (ApiError, OSError) as e:
            report.boards[board_id] = {"pushed": 0, "pulled": 0, "error": str(e)}
    state.save()
    report.wrote, report.news = write_cloud_data(install, boards, state, now)
    return report

