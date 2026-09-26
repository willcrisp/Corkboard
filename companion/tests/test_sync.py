import json
import shutil
import subprocess
from pathlib import Path

import pytest

from conftest import BOARD, SECRET, T0, make_board, make_install, note, snapshot
from corkboard_companion import discover, luadata, sync
from corkboard_companion.api import Api, ApiError
from corkboard_companion.config import State

REPO = Path(__file__).resolve().parents[2]
NEW_SECRET = "zyxwvutsrqponmlkjihgfedc"


def state(tmp_path, name="state.json"):
    return State(tmp_path / name)


def install_at(folder):
    return discover.find([folder.parent])


def test_first_sync_registers_the_board_and_pushes_everything(tmp_path, api, server):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1), note(2)])]})
    report = sync.run(api, install_at(folder), state(tmp_path), now=T0 + 500)
    assert report.boards[BOARD]["error"] is None
    assert report.boards[BOARD]["pushed"] == 4  # 2 notes, 1 member, the name
    body = server.post(f"/v1/boards/{BOARD}/sync", json={"cursor": 0},
                       headers={"Authorization": f"Bearer {BOARD}.{SECRET}"}).json()
    assert sorted(n["id"] for n in body["notes"]) == ["a1b2c3d4-0001", "a1b2c3d4-0002"]
    assert body["meta"]["name"] == "MC prep"


def test_second_sync_pushes_only_what_changed(tmp_path, api):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1), note(2)])]})
    st = state(tmp_path)
    sync.run(api, install_at(folder), st, now=T0 + 500)
    make_install(tmp_path / "wow", {"ACC1": [make_board([note(1), note(2, rev=T0 + 9, text="edited")])]})
    report = sync.run(api, install_at(folder), State(tmp_path / "state.json"), now=T0 + 600)
    assert report.boards[BOARD]["pushed"] == 1


def test_never_writes_savedvariables_and_writes_data_atomically(tmp_path, api):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1)])], "ACC2": [make_board([note(2)])]})
    before = snapshot(tmp_path / "wow")
    sync.run(api, install_at(folder), state(tmp_path), now=T0 + 500)
    after = snapshot(tmp_path / "wow")
    changed = {p for p in after if before.get(p) != after[p]}
    assert changed == {folder / "Interface" / "AddOns" / "Corkboard_Cloud" / "Data.lua"}
    assert not list((folder / "Interface" / "AddOns" / "Corkboard_Cloud").glob("*.tmp"))


def test_data_lua_holds_only_what_the_addon_lacks(tmp_path, api):
    # Two accounts on the same install hold different notes: after a sync, the
    # server has both, and Data.lua carries nothing both accounts already have.
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1)])]})
    sync.run(api, install_at(folder), state(tmp_path), now=T0 + 500)
    # Another member's companion pushes note 3.
    other = make_install(tmp_path / "wow2", {"ACC9": [make_board([note(3, author="Bob-Realm", editor="Bob-Realm")])]})
    sync.run(api, install_at(other), state(tmp_path, "other.json"), now=T0 + 510)
    # Ours pulls it: it lands in Data.lua, not SavedVariables.
    report = sync.run(api, install_at(folder), State(tmp_path / "state.json"), now=T0 + 520)
    assert report.wrote and report.news
    data = luadata.load(install_at(folder).cloud_data)["CorkboardCloudData"]
    entry = data["boards"][BOARD]
    assert [n["id"] for n in entry["notes"]] == ["a1b2c3d4-0003"]
    assert entry["syncedAt"] == T0 + 520 and entry["cursor"] >= 1
    # Nothing new: only the sync time moves, so there's no news for the player.
    again = sync.run(api, install_at(folder), State(tmp_path / "state.json"), now=T0 + 530)
    assert again.wrote and not again.news
    # Once the addon has merged it (it's in SavedVariables), Data.lua empties out.
    make_install(tmp_path / "wow", {"ACC1": [make_board([note(1), note(3, author="Bob-Realm", editor="Bob-Realm")])]})
    sync.run(api, install_at(folder), State(tmp_path / "state.json"), now=T0 + 540)
    data = luadata.load(install_at(folder).cloud_data)["CorkboardCloudData"]
    assert data["boards"][BOARD]["notes"] in ({}, [])


def test_boards_without_cloud_sync_are_left_alone(tmp_path, api):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1)], cloud=False)]})
    report = sync.run(api, install_at(folder), state(tmp_path), now=T0)
    assert report.boards == {}
    assert report.line() == "no boards with cloud sync on"


def test_a_rotated_secret_is_carried_to_the_server(tmp_path, api):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1)])]})
    sync.run(api, install_at(folder), state(tmp_path), now=T0)
    # The owner rotates in game: the new secret, with the old one kept.
    make_install(tmp_path / "wow", {"ACC1": [make_board([note(1), note(2)], secret=NEW_SECRET, old=[SECRET])]})
    report = sync.run(api, install_at(folder), State(tmp_path / "state.json"), now=T0 + 10)
    assert report.boards[BOARD]["error"] is None
    with pytest.raises(ApiError) as e:
        api.sync(BOARD, SECRET, 0, [], [], None)
    assert e.value.status == 401
    assert api.sync(BOARD, NEW_SECRET, 0, [], [], None)["cursor"] >= 1


def test_a_refused_secret_is_reported(tmp_path, api):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1)])]})
    sync.run(api, install_at(folder), state(tmp_path), now=T0)
    api.rotate(BOARD, SECRET, NEW_SECRET)  # someone else rotated; we never got the new invite
    report = sync.run(api, install_at(folder), State(tmp_path / "state.json"), now=T0 + 10)
    assert "rejoin" in report.boards[BOARD]["error"]
    assert State(tmp_path / "state.json").boards[BOARD].auth_failed


def test_large_boards_go_in_several_requests(tmp_path, api):
    notes = [note(i, text="x" * 1500) for i in range(1, 80)]
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board(notes)]})
    report = sync.run(api, install_at(folder), state(tmp_path), now=T0)
    assert report.boards[BOARD]["error"] is None
    posts = [p for m, p in api.opener_log if p.endswith("/sync")]
    assert len(posts) >= 3


def test_unreadable_savedvariables_are_skipped(tmp_path, api):
    folder = make_install(tmp_path / "wow", {"ACC1": [make_board([note(1)])]})
    bad = folder / "WTF" / "Account" / "ACC2" / "SavedVariables"
    bad.mkdir(parents=True)
    (bad / "Corkboard.lua").write_text("CorkboardDB = os.exit()")
    boards = sync.read_boards(install_at(folder))
    assert list(boards) == [BOARD]


@pytest.mark.skipif(shutil.which("lua5.1") is None, reason="needs lua5.1 with busted's helpers")
def test_the_addon_loads_what_the_companion_writes(tmp_path, api):
    """§12 Phase 5: B edits and logs out; with nobody else online, A's companion
    syncs, then A /reloads and sees B's edits. Here A's /reload is the real
    addon in the fake client, reading the Data.lua the companion wrote."""
    link = "|cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r"
    a_folder = make_install(tmp_path / "a", {"ACC1": [make_board([note(1)])]})
    b_folder = make_install(tmp_path / "b", {"ACC2": [make_board([
        note(1), note(2, author="Bob-Realm", editor="Bob-Realm", text=f"Need 4x {link}\nand \"quotes\" é"),
        note(3, author="Bob-Realm", editor="Bob-Realm", text=link) | {"kind": "gear"}])]})
    sync.run(api, install_at(a_folder), state(tmp_path, "a.json"), now=T0 + 100)
    sync.run(api, install_at(b_folder), state(tmp_path, "b.json"), now=T0 + 200)  # B's edits reach the cloud
    sync.run(api, install_at(a_folder), state(tmp_path, "a.json"), now=T0 + 300)  # A's companion pulls them
    sv = a_folder / "WTF" / "Account" / "ACC1" / "SavedVariables" / "Corkboard.lua"
    out = subprocess.run(["lua5.1", "companion/tests/load_cloud.lua", str(sv), str(install_at(a_folder).cloud_data)],
                         cwd=REPO, capture_output=True, check=True)
    boards = json.loads(out.stdout)
    notes = boards[BOARD]["notes"]
    assert notes["a1b2c3d4-0002"]["text"] == f"Need 4x {link}\nand \"quotes\" é"
    assert notes["a1b2c3d4-0003"]["kind"] == "gear"  # a gear-feed entry (§9.1) keeps its kind end to end
    assert boards[BOARD]["sync"]["lastCloudAt"] == T0 + 300
