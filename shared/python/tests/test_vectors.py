"""Every case in shared/test-vectors, as the Lua suite runs them."""

import itertools
import copy

import pytest

from conftest import load, record, text_input
from corkcore import digest, invite, merge, sanitise, util

SANITISE = load("sanitise.json")
MERGE = load("merge.json")
DIGEST = load("digest.json")
FNV = load("fnv1a32.json")
INVITE = load("invite.json")


def ids(cases):
    return [c["name"] if "name" in c else str(i) for i, c in enumerate(cases)]


@pytest.mark.parametrize("case", FNV["cases"], ids=ids(FNV["cases"]))
def test_fnv1a32(case):
    value = text_input(case)
    assert util.fnv1a32(value) == case["fnv1a32"]


@pytest.mark.parametrize("case", SANITISE["text"], ids=ids(SANITISE["text"]))
def test_sanitise_text(case):
    ok, reason = sanitise.text(text_input(case))
    assert ok == case["ok"]
    assert reason == case.get("reason")


@pytest.mark.parametrize("case", SANITISE["name"], ids=ids(SANITISE["name"]))
def test_sanitise_name(case):
    assert sanitise.name(text_input(case)) == case["ok"]


@pytest.mark.parametrize("case", SANITISE["board_name"], ids=ids(SANITISE["board_name"]))
def test_sanitise_board_name(case):
    assert sanitise.board_name(text_input(case)) == case["ok"]


@pytest.mark.parametrize("kind", ["note", "member", "meta"])
def test_sanitise_records(kind):
    section = SANITISE[kind]
    check = getattr(sanitise, kind)
    for case in section["cases"]:
        value = record(section["base"], case)
        clean, reason = check(value)
        if case["ok"]:
            assert reason is None, case["name"]
            assert clean == case.get("output", value), case["name"]
            assert clean is not value
        else:
            assert clean is None, case["name"]
            assert reason == case["reason"], case["name"]


SECTIONS = {"notes": ("id", merge.apply_note), "members": ("name", merge.apply_member)}


def board_from(spec, field, key):
    return {"clock": spec["clock"], field: {r[key]: copy.deepcopy(r) for r in spec.get(field, [])}}


@pytest.mark.parametrize("field", ["notes", "members"])
def test_merge_vectors(field):
    key, apply = SECTIONS[field]
    for case in MERGE[field]:
        expected = {r[key]: r for r in case["expect"][field]}
        board = board_from(case["board"], field, key)
        results = []
        for rec in case["apply"]:
            ok, reason = apply(board, copy.deepcopy(rec))
            results.append("stored" if ok else reason)
        assert results == case["results"], case["name"]
        assert board["clock"] == case["expect"]["clock"], case["name"]
        assert board[field] == expected, case["name"]
        # Every order, applied twice.
        for order in itertools.permutations(case["apply"]):
            board = board_from(case["board"], field, key)
            for _ in range(2):
                for rec in order:
                    apply(board, copy.deepcopy(rec))
            assert board["clock"] == case["expect"]["clock"], case["name"]
            assert board[field] == expected, case["name"]


def test_merge_meta_vectors():
    for case in MERGE["meta"]:
        def fresh():
            return {"clock": case["board"]["clock"], "meta": copy.deepcopy(case["board"].get("meta"))}

        board = fresh()
        results = []
        for rec in case["apply"]:
            ok, reason = merge.apply_meta(board, copy.deepcopy(rec))
            results.append("stored" if ok else reason)
        assert results == case["results"], case["name"]
        assert board["clock"] == case["expect"]["clock"], case["name"]
        assert board["meta"] == case["expect"].get("meta"), case["name"]
        for order in itertools.permutations(case["apply"]):
            board = fresh()
            for _ in range(2):
                for rec in order:
                    merge.apply_meta(board, copy.deepcopy(rec))
            assert board["meta"] == case["expect"].get("meta"), case["name"]


def test_digest_vectors():
    for case in DIGEST["bucket"]:
        assert digest.bucket(case["id"]) == case["bucket"]
    for case in DIGEST["line"]:
        assert digest.line(case["note"]) == case["line"]
    for case in DIGEST["boards"]:
        result = digest.compute(case["notes"])
        assert result["count"] == case["count"], case["name"]
        assert result["buckets"] == case["buckets"], case["name"]
        assert result["digest"] == case["digest"], case["name"]


@pytest.mark.parametrize("case", INVITE["encode"], ids=ids(INVITE["encode"]))
def test_invite_encode(case):
    assert invite.encode(case["board"]) == case["invite"]


@pytest.mark.parametrize("case", INVITE["decode"], ids=ids(INVITE["decode"]))
def test_invite_decode(case):
    out, reason = invite.decode(case["input"])
    if case["ok"]:
        assert out == case["output"]
    else:
        assert out is None
        assert reason == case["reason"]
