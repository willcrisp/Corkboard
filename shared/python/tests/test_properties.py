"""Hypothesis property tests (docs/design.md §11): the merge laws, and
convergence of 3-5 nodes plus a server under reordered, duplicated and
dropped deliveries."""

import copy

from hypothesis import given, settings
from hypothesis import strategies as st

from corkcore import digest, merge

T0 = 1790000000
IDS = ["aaaaaaaa-1", "aaaaaaaa-2", "bbbbbbbb-1"]
NAMES = ["Amy-Realm", "Bob-Realm", "bob-Realm", "Øystein-Realm"]
TEXTS = ["a", "b", "|cffff0000c|r", ""]


@st.composite
def notes(draw):
    deleted = draw(st.booleans())
    note = {
        "id": draw(st.sampled_from(IDS)),
        "author": draw(st.sampled_from(NAMES)),
        "created": T0 + draw(st.integers(0, 2)),
        "rev": draw(st.sampled_from([0, T0 + 1, T0 + 2, T0 + 3])),  # rev 0 is invalid: dropped
        "editor": draw(st.sampled_from(NAMES)),
        "text": "" if deleted else draw(st.sampled_from(TEXTS)),
        "color": draw(st.integers(1, 2)),
        "deleted": deleted,
    }
    kind = draw(st.sampled_from([None, "gear", "quests"]))  # so ties between kinds and plain notes come up
    if kind is not None:
        note["kind"] = kind
    return note


def merged(records):
    board = {"clock": 0}
    for record in records:
        merge.apply_note(board, copy.deepcopy(record))
    return board


@given(st.lists(notes(), max_size=8), st.randoms())
def test_merge_is_order_independent(records, rnd):
    shuffled = list(records)
    rnd.shuffle(shuffled)
    assert merged(records) == merged(shuffled)


@given(st.lists(notes(), max_size=8))
def test_merge_is_idempotent(records):
    assert merged(records) == merged(records + records)


@given(st.lists(notes(), max_size=6), st.lists(notes(), max_size=6))
def test_merge_is_associative(a, b):
    # Merging b into a board holding a == merging the boards' contents in one go.
    left = merged(a)
    for note in b:
        merge.apply_note(left, copy.deepcopy(note))
    assert left == merged(a + b)


@given(st.lists(notes(), min_size=1, max_size=6))
def test_winner_is_the_maximum(records):
    board = merged(records)
    for note_id, winner in board.get("notes", {}).items():
        for record in records:
            if record["id"] == note_id and record["rev"] >= 1:
                assert merge.compare_note(winner, record) >= 0


# Convergence ------------------------------------------------------------------------

OPS = st.lists(
    st.tuples(
        st.integers(0, 4),  # which node acts
        st.sampled_from(["create", "edit", "delete"]),
        st.integers(0, 5),  # which note (by index among that board's)
        st.integers(0, 30),  # seconds later
    ),
    min_size=1,
    max_size=40,
)


@settings(max_examples=150, deadline=None)
@given(st.integers(3, 5), OPS, st.randoms())
def test_nodes_and_server_converge(size, ops, rnd):
    names = [f"Node{i}-Realm" for i in range(size)]
    nodes = [{"clock": 0} for _ in range(size)]
    server = {"clock": 0}
    counters = [0] * size
    in_flight = []  # (receiver, record)
    now = T0
    for who, kind, pick, later in ops:
        who %= size
        now += later
        board = nodes[who]
        live = sorted(i for i, n in board.get("notes", {}).items() if not n["deleted"])
        if kind == "create" or not live:
            counters[who] += 1
            record, _ = merge.create_note(board, {"id": f"{who:08x}-{counters[who]:04d}", "author": names[who],
                                                  "text": f"n{counters[who]}"}, now)
        elif kind == "edit":
            record, _ = merge.edit_note(board, live[pick % len(live)], {"text": f"e{now}"}, names[who], now)
        else:
            record, _ = merge.delete_note(board, live[pick % len(live)], names[who], now)
        # Live delivery: dropped, duplicated or delayed, per receiver.
        for receiver in range(size + 1):
            if receiver == who:
                continue
            for _ in range(rnd.choice([0, 1, 1, 2])):
                in_flight.append((receiver, copy.deepcopy(record)))
        rnd.shuffle(in_flight)
        # Deliver some of what's in flight, in random order.
        keep = []
        for receiver, rec in in_flight:
            if rnd.random() < 0.5:
                merge.apply_note(server if receiver == size else nodes[receiver], rec)
            else:
                keep.append((receiver, rec))
        in_flight = keep
    # Heal: every node syncs with the server (the companion path), then with each other.
    for node in nodes:
        for note in list(node.get("notes", {}).values()):
            merge.apply_note(server, copy.deepcopy(note))
    for node in nodes:
        for note in list(server.get("notes", {}).values()):
            merge.apply_note(node, copy.deepcopy(note))
    target = digest.compute(server.get("notes", {}))["digest"]
    for node in nodes:
        assert digest.compute(node.get("notes", {}))["digest"] == target
        assert node["notes"] == server["notes"]
