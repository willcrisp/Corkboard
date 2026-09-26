import math

import pytest

from corkboard_companion import luadata

# What the client writes: brackets, trailing commas, "-- [n]" comments, escapes.
SAVED = rb'''
CorkboardDB = {
["global"] = {
["boards"] = {
["k3f9x2m7q1pz8c4w"] = {
["notes"] = {
["a1b2c3d4-0001"] = {
["text"] = "Need 4x |cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r\nfor \"MC\" \\ \195\169",
["rev"] = 1790000456,
["deleted"] = false,
["color"] = 1,
},
},
["oldSecrets"] = {
"old1", -- [1]
"old2", -- [2]
},
["cloud"] = true,
["weird"] = -1.5e3,
["hex"] = 0x1F,
},
},
},
["profileKeys"] = {
["Will - Mirage Raceway"] = "Will - Mirage Raceway",
},
}
--[[ a block
comment ]]
Other = nil
Third = [==[long
string]==]; Fourth = 'single \65\066'
'''


def test_reads_what_the_client_writes():
    data = luadata.loads(SAVED)
    board = data["CorkboardDB"]["global"]["boards"]["k3f9x2m7q1pz8c4w"]
    note = board["notes"]["a1b2c3d4-0001"]
    assert note["text"] == 'Need 4x |cffffffff|Hitem:13444::::::::60:::::::::|h[Major Mana Potion]|h|r\nfor "MC" \\ é'
    assert note["rev"] == 1790000456 and isinstance(note["rev"], int)
    assert note["deleted"] is False
    assert board["oldSecrets"] == ["old1", "old2"]
    assert board["weird"] == -1500 and board["hex"] == 31
    assert data["Other"] is None
    assert data["Third"] == "long\nstring"
    assert data["Fourth"] == "single AB"


def test_invalid_utf8_survives_as_surrogates():
    data = luadata.loads(b'X = "a\\255b\xffc"')
    assert data["X"].encode("utf-8", "surrogateescape") == b"a\xffb\xffc"


@pytest.mark.parametrize("bad", [
    b"X = os.exit()", b"X = {", b'X = "unterminated', b"X = 1 + 2", b"X = function() end", b"= 1",
    b'X = "\\q"', b"X = {[nil] = 1}", b'X = "\\300"', b"X = inf",
])
def test_refuses_anything_but_data(bad):
    with pytest.raises(luadata.LuaSyntaxError):
        luadata.loads(bad)


def test_round_trip():
    value = {
        "version": 1,
        "boards": {"k3f9x2m7q1pz8c4w": {"notes": [{"text": 'q"\\\n\r\t\x00\x7fé日😀', "rev": 2**53 - 1}],
                                          "members": [], "meta": None, "flag": True, "f": 1.25}},
        "end": "x",
        "and": 1,  # a keyword key
        7: "number key",
    }
    text = luadata.dumps("CorkboardCloudData", value, "header line\nsecond")
    assert text.startswith(b"-- header line\n-- second\nCorkboardCloudData = {")
    back = luadata.loads(text)["CorkboardCloudData"]
    expected = dict(value)
    expected["boards"] = {"k3f9x2m7q1pz8c4w": {"notes": [{"text": 'q"\\\n\r\t\x00\x7fé日😀', "rev": 2**53 - 1}],
                                                "members": {}, "flag": True, "f": 1.25}}
    assert back == expected


def test_refuses_to_write_what_lua_cant_hold():
    with pytest.raises(ValueError):
        luadata.dumps("1bad", 1)
    with pytest.raises(ValueError):
        luadata.dumps("X", math.nan)
    with pytest.raises(ValueError):
        luadata.dumps("X", {(1, 2): 1})
    with pytest.raises(ValueError):
        luadata.dumps("X", object())


def test_file_helpers(tmp_path):
    path = tmp_path / "x.lua"
    luadata.dump(path, "X", {"a": 1})
    assert luadata.load(path) == {"X": {"a": 1}}
    (tmp_path / "bom.lua").write_bytes(b"\xef\xbb\xbfY = 2")
    assert luadata.load(tmp_path / "bom.lua") == {"Y": 2}
