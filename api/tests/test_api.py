import sqlite3

from hypothesis import given, settings
from hypothesis import strategies as st

from conftest import BOARD, SECRET, T0, auth, note
from corkcore import digest

NEW_SECRET = "zyxwvutsrqponmlkjihgfedc"


def sync(api, body, **kw):
    return api.post(f"/v1/boards/{BOARD}/sync", json=body, headers=kw.get("headers", auth()))


def test_health(api):
    r = api.get("/v1/health")
    assert r.status_code == 200 and r.json() == {"ok": True}


def test_register(api):
    assert api.post("/v1/boards", json={"id": BOARD, "secret": SECRET}).status_code == 201
    assert api.post("/v1/boards", json={"id": BOARD, "secret": SECRET}).status_code == 409
    assert api.post("/v1/boards", json={"id": "short", "secret": SECRET}).status_code == 400
    assert api.post("/v1/boards", json={"id": BOARD, "secret": "x"}).status_code == 400
    assert api.post("/v1/boards", content=b"[1]").status_code == 400
    assert api.post("/v1/boards", content=b"{nope").status_code == 400


def test_the_server_stores_only_a_hash(api, board, tmp_path):
    row = sqlite3.connect(tmp_path / "cork.db").execute("SELECT secret_hash FROM boards").fetchone()
    assert SECRET.encode() not in row[0]
    assert len(row[0]) == 32


def test_push_then_pull(api, board):
    r = sync(api, {"cursor": 0, "notes": [note(1), note(2)], "members": [
        {"name": "Will-Realm", "role": "owner", "rev": T0, "editor": "Will-Realm", "removed": False}],
        "meta": {"name": "MC prep", "rev": T0, "editor": "Will-Realm"}})
    assert r.status_code == 200
    body = r.json()
    assert body["cursor"] == 4 and body["more"] is False and body["rejected"] == []
    assert [n["id"] for n in body["notes"]] == ["a1b2c3d4-0001", "a1b2c3d4-0002"]
    assert body["meta"]["name"] == "MC prep"
    # Nothing new since cursor 4.
    again = sync(api, {"cursor": 4}).json()
    assert again["notes"] == [] and again["members"] == [] and again["meta"] is None and again["cursor"] == 4
    # Another member edits note 1; the first pulls only that.
    sync(api, {"cursor": 4, "notes": [note(1, rev=T0 + 9, text="edited")]})
    pulled = sync(api, {"cursor": 4}).json()
    assert [n["text"] for n in pulled["notes"]] == ["edited"]
    assert pulled["cursor"] == 5


def test_merge_rules_hold_on_the_server(api, board):
    sync(api, {"notes": [note(1, rev=T0 + 5, text="newer")]})
    stale = sync(api, {"cursor": 1, "notes": [note(1, rev=T0 + 2, text="older")]}).json()
    assert stale["notes"] == [] and stale["cursor"] == 1
    sync(api, {"notes": [note(1, rev=T0 + 6, deleted=True)]})
    # A stale live copy never brings a deleted note back.
    sync(api, {"notes": [note(1, rev=T0 + 5, text="newer")]})
    everything = sync(api, {"cursor": 0}).json()
    assert everything["notes"][0]["deleted"] is True
    # Tie on (rev, editor): the tombstone wins, as in the addon.
    assert sync(api, {"notes": [note(1, rev=T0 + 6, text="tie")]}).json()["cursor"] == everything["cursor"]


def test_gear_entries_keep_their_kind(api, board):
    gear = note(1) | {"kind": "gear"}
    assert sync(api, {"notes": [gear, note(2)]}).json()["rejected"] == []
    pulled = sync(api, {"cursor": 0}).json()["notes"]
    assert pulled[0] == gear and "kind" not in pulled[1]
    # Exact (rev, editor) tie: the copy with a kind wins, as in the addon.
    assert sync(api, {"cursor": 2, "notes": [note(2) | {"kind": "gear"}]}).json()["notes"][0]["kind"] == "gear"
    assert sync(api, {"notes": [note(3) | {"kind": "poll"}]}).json()["rejected"][0]["reason"] == "kind"


def test_quest_logs_keep_their_kind(api, board):
    log = note(1, text="7:5,46:10") | {"kind": "quests"}
    assert sync(api, {"notes": [log]}).json()["rejected"] == []
    assert sync(api, {"cursor": 0}).json()["notes"] == [log]


def test_player_notes_keep_their_kind(api, board):
    entry = note(1, text="P1;avoid;Gankalot\nNinja'd the chest") | {"kind": "player"}
    assert sync(api, {"notes": [entry]}).json()["rejected"] == []
    assert sync(api, {"cursor": 0}).json()["notes"] == [entry]


def test_a_database_from_before_note_kinds_is_upgraded(make_client, tmp_path):
    old = sqlite3.connect(tmp_path / "cork.db")
    old.executescript("""
        CREATE TABLE notes (board_id TEXT NOT NULL, note_id TEXT NOT NULL, author TEXT NOT NULL,
            created INTEGER NOT NULL, rev INTEGER NOT NULL, editor TEXT NOT NULL, text TEXT NOT NULL,
            color INTEGER NOT NULL, deleted INTEGER NOT NULL, seq INTEGER NOT NULL, PRIMARY KEY (board_id, note_id));
    """)
    old.close()
    api = make_client()
    assert api.post("/v1/boards", json={"id": BOARD, "secret": SECRET}).status_code == 201
    assert sync(api, {"notes": [note(1) | {"kind": "gear"}]}).json()["notes"][0]["kind"] == "gear"


def test_rejects_what_the_sanitiser_rejects(api, board):
    bad = note(3, text="|TInterface\\Icons\\x:0|t")
    r = sync(api, {"notes": [bad, {"id": "nope"}, 5], "members": [{"name": "x"}], "meta": {"name": ""}}).json()
    reasons = sorted(x["reason"] for x in r["rejected"])
    assert reasons == ["escape", "id", "name", "name", "type"]
    assert r["notes"] == []


def test_bad_bodies(api, board):
    assert sync(api, {"cursor": -1}).status_code == 400
    assert sync(api, {"cursor": 1.5}).status_code == 400
    assert sync(api, {"notes": {}}).status_code == 400
    assert sync(api, {"members": "x"}).status_code == 400


def test_wrong_secret_gives_401(api, board):
    assert sync(api, {}, headers=auth(secret="wrongwrongwrongwrong")).status_code == 401
    assert sync(api, {}, headers={}).status_code == 401
    assert sync(api, {}, headers={"Authorization": f"Basic {BOARD}.{SECRET}"}).status_code == 401
    assert api.post(f"/v1/boards/{BOARD}/sync", json={}, headers=auth(board="zzzzzzzzzzzzzzzz")).status_code == 401
    unknown = "zzzzzzzzzzzzzzzz"
    assert api.post(f"/v1/boards/{unknown}/sync", json={}, headers=auth(board=unknown)).status_code == 401


def test_rotation_invalidates_the_old_secret(api, board):
    r = api.post(f"/v1/boards/{BOARD}/rotate", json={"secret": NEW_SECRET}, headers=auth())
    assert r.status_code == 200
    assert sync(api, {}).status_code == 401
    assert sync(api, {}, headers=auth(secret=NEW_SECRET)).status_code == 200
    assert api.post(f"/v1/boards/{BOARD}/rotate", json={"secret": "short"},
                    headers=auth(secret=NEW_SECRET)).status_code == 400


def test_rate_limits_return_429(api, board, clock):
    for _ in range(60):
        assert sync(api, {}).status_code == 200
    r = sync(api, {})
    assert r.status_code == 429 and int(r.headers["Retry-After"]) >= 1
    clock.t += 61
    assert sync(api, {}).status_code == 200


def test_registration_limit(make_client):
    api = make_client(register_rate=3)
    for i in range(3):
        assert api.post("/v1/boards", json={"id": f"{i:016d}", "secret": SECRET}).status_code == 201
    assert api.post("/v1/boards", json={"id": "9" * 16, "secret": SECRET}).status_code == 429


def test_trusted_proxy_forwarded_for(make_client):
    api = make_client(register_rate=1, trusted_proxy="testclient")
    ok = api.post("/v1/boards", json={"id": "1" * 16, "secret": SECRET}, headers={"X-Forwarded-For": "1.1.1.1"})
    assert ok.status_code == 201
    other = api.post("/v1/boards", json={"id": "2" * 16, "secret": SECRET}, headers={"X-Forwarded-For": "2.2.2.2"})
    assert other.status_code == 201
    again = api.post("/v1/boards", json={"id": "3" * 16, "secret": SECRET}, headers={"X-Forwarded-For": "2.2.2.2"})
    assert again.status_code == 429


def test_body_limit_413(api, board):
    big = [note(i, text="x" * 1900) for i in range(40)]
    assert sync(api, {"notes": big}).status_code == 413


def test_board_note_limit(make_client):
    api = make_client(max_notes=3)
    api.post("/v1/boards", json={"id": BOARD, "secret": SECRET})
    r = sync(api, {"notes": [note(i) for i in range(1, 6)]}).json()
    assert [x["reason"] for x in r["rejected"]] == ["board_full", "board_full"]
    # Edits to notes it holds still go through.
    assert sync(api, {"cursor": r["cursor"], "notes": [note(1, rev=T0 + 50)]}).json()["notes"][0]["rev"] == T0 + 50


def test_a_500_note_board_catches_up_entirely_through_the_api(make_client):
    """§12 Phase 5: a 500-note board catches up via the cloud, in pages."""
    api = make_client(page=200)
    api.post("/v1/boards", json={"id": BOARD, "secret": SECRET})
    notes = [note(i, text=f"note {i} " + "x" * 40) for i in range(1, 501)]
    for start in range(0, 500, 100):
        assert sync(api, {"notes": notes[start:start + 100]}).status_code == 200
    got, cursor = [], 0
    while True:
        r = sync(api, {"cursor": cursor}).json()
        got += r["notes"]
        cursor = r["cursor"]
        if not r["more"]:
            break
    assert len(got) == 500
    server = api.get(f"/v1/boards/{BOARD}/digest", headers=auth()).json()
    assert server["count"] == 500
    assert server["digest"] == digest.compute(notes)["digest"]


def test_logs_never_carry_the_secret(api, board, caplog):
    caplog.set_level("INFO", logger="corkboard.api")
    sync(api, {"notes": [note(1)]})
    text = caplog.text
    assert SECRET not in text and "Bearer" not in text
    assert f"board={BOARD}" in text and "status=200" in text


RECORD = st.builds(
    lambda i, rev, editor, deleted, text: note(i, rev=T0 + rev, editor=editor, deleted=deleted, text=text),
    st.integers(1, 4), st.integers(1, 5), st.sampled_from(["Amy-Realm", "Bob-Realm"]), st.booleans(),
    st.sampled_from(["a", "b", "c"]),
)


@settings(max_examples=40, deadline=None)
@given(st.lists(st.lists(RECORD, max_size=6), min_size=2, max_size=4))
def test_companions_converge_through_the_api(tmp_path_factory, batches):
    """Several companions push in turn, then each pulls from cursor 0: all see the same board."""
    from fastapi.testclient import TestClient

    from corkboard_api.app import create_app
    from corkboard_api.config import Settings

    path = tmp_path_factory.mktemp("prop") / "cork.db"
    with TestClient(create_app(Settings(db=str(path), board_rate=10_000))) as api:
        api.post("/v1/boards", json={"id": BOARD, "secret": SECRET})
        for batch in batches:
            assert sync(api, {"notes": batch}).status_code == 200
        pulled = sync(api, {"cursor": 0}).json()["notes"]
        # The server holds the §4.3 winner of each id among everything pushed.
        from corkcore import merge

        board = {"clock": 0}
        for batch in reversed(batches):
            merge.apply_notes(board, batch)
        assert {n["id"]: n for n in pulled} == board.get("notes", {})


def test_offline_digest_tool_matches_the_endpoint(api, board, tmp_path):
    from corkboard_api import tools

    sync(api, {"notes": [note(1), note(2)]})
    live = api.get(f"/v1/boards/{BOARD}/digest", headers=auth()).json()
    (line,) = tools.digest(str(tmp_path / "cork.db"))
    assert line == f"{BOARD} digest={live['digest']:08x} notes=2 cursor={live['cursor']}"
    assert tools.main(["x"]) == 2
