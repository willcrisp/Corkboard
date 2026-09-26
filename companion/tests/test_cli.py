import argparse

import pytest

from conftest import BOARD, T0, make_board, make_install, note
from corkboard_companion import cli, discover
from corkboard_companion.config import Config, State


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("CORKBOARD_COMPANION_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(cli, "wow_running", lambda: True)
    return tmp_path / "home"


def test_discovery_prefers_forever_and_corkboard(tmp_path):
    root = tmp_path / "wow"
    make_install(root, {}, product="_retail_", flavour="wow")
    make_install(root, {}, product="_classic_beta_", flavour="wow_classic_beta")
    (root / "_classic_era_").mkdir()
    found = discover.installs(root)
    assert found[0].product.name == "_classic_beta_"
    assert found[-1].product.name == "_classic_era_" and not found[-1].has_corkboard
    assert discover.find([root]).product.name == "_classic_beta_"
    assert discover.find([root], "_retail_").product.name == "_retail_"
    assert discover.find([tmp_path / "missing"]) is None
    assert discover.read_flavour(root / "_classic_era_") is None
    assert discover.default_roots()


def test_setup_status_and_sync(tmp_path, api, monkeypatch, capsys):
    root = tmp_path / "wow"
    make_install(root, {"ACC1": [make_board([note(1)])]})
    args = argparse.Namespace(api="https://corkboard.test", wow=str(root), product=None)
    assert cli.setup(Config.load(), args, interactive=False) == 0
    assert "Using" in capsys.readouterr().out
    config = Config.load()
    assert config.api_url == "https://corkboard.test" and config.wow_root == str(root)
    monkeypatch.setattr(cli, "Api", lambda url: api)
    assert cli.once(config) == 0
    assert "pushed 3" in capsys.readouterr().out
    assert cli.status(config) == 0
    out = capsys.readouterr().out
    assert f"{BOARD}: 1 notes, last synced" in out and "never" not in out
    assert State().boards[BOARD].cursor >= 1


def test_not_set_up(tmp_path, capsys):
    config = Config(wow_root=str(tmp_path / "nothing"))
    assert cli.once(config) == 1
    assert cli.status(config) == 1
    assert cli.watch(config) == 1
    args = argparse.Namespace(api=None, wow=str(tmp_path / "nothing"), product=None)
    assert cli.setup(config, args, interactive=False) == 1


def test_watch_syncs_once_then_on_changes(tmp_path, api, monkeypatch, capsys):
    root = tmp_path / "wow"
    make_install(root, {"ACC1": [make_board([note(1)])]})
    monkeypatch.setattr(cli, "Api", lambda url: api)
    monkeypatch.setattr(cli, "POLL", 0)
    monkeypatch.setattr(cli, "SETTLE", 0)
    config = Config(api_url="https://corkboard.test", wow_root=str(root))
    assert cli.watch(config, stop_after=0.2) == 0
    assert "pushed" in capsys.readouterr().out


def test_config_round_trip(home):
    Config(api_url="https://x", product="_classic_beta_").save()
    assert Config.load().product == "_classic_beta_"
    (home / "config.json").write_text("{not json")
    assert Config.load().api_url == ""


def test_main_dispatch(tmp_path, monkeypatch):
    assert cli.main(["status"]) == 1
    with pytest.raises(SystemExit):
        cli.main(["--version"])


def test_gui_helpers(tmp_path, monkeypatch):
    from corkboard_companion import gui

    root = tmp_path / "wow"
    make_install(root, {}, product="_classic_beta_")
    found = gui.candidates(str(root))
    assert [gui.label(i) for i in found] == ["_classic_beta_ (wow_classic_beta)"]
    assert gui.check_api("ftp://nope").startswith("The address should")
    assert gui.check_api("http://localhost:1").startswith("Couldn't reach it")
    # --cli runs the command line; without tkinter the window falls back to it too.
    assert gui.main(["--cli", "status"]) == 1
