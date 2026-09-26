import io
import urllib.error
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from corkboard_api.app import create_app
from corkboard_api.config import Settings
from corkboard_companion import luadata
from corkboard_companion.api import Api

T0 = 1790000000
BOARD = "k3f9x2m7q1pz8c4w"
SECRET = "a1b2c3d4e5f6g7h8i9j0k1l2"


class _Response:
    def __init__(self, body: bytes):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class TestClientOpener:
    """Lets the urllib-based Api talk to the FastAPI app in-process."""

    def __init__(self, client: TestClient):
        self.client = client
        self.requests = []

    def open(self, req, timeout=None):
        path = req.full_url.split("://", 1)[1].split("/", 1)[1]
        headers = {k: v for k, v in req.header_items()}
        self.requests.append((req.get_method(), "/" + path))
        r = self.client.request(req.get_method(), "/" + path, content=req.data, headers=headers)
        if r.status_code >= 400:
            raise urllib.error.HTTPError(req.full_url, r.status_code, "", r.headers, io.BytesIO(r.content))
        return _Response(r.content)


@pytest.fixture
def server(tmp_path):
    with TestClient(create_app(Settings(db=str(tmp_path / "api.db"), board_rate=10_000))) as client:
        yield client


@pytest.fixture
def api(server):
    opener = TestClientOpener(server)
    a = Api("https://corkboard.test", opener=opener)
    a.opener_log = opener.requests
    return a


def note(i, rev=T0 + 1, text=None, editor="Will-Realm", author="Will-Realm", deleted=False):
    return {"id": f"a1b2c3d4-{i:04d}", "author": author, "created": T0, "rev": rev, "editor": editor,
            "text": "" if deleted else (text if text is not None else f"note {i}"), "color": 1, "deleted": deleted}


def make_board(notes=(), secret=SECRET, cloud=True, old=(), members=None, name="MC prep"):
    return {
        "id": BOARD, "secret": secret, "owner": "Will-Realm", "created": T0, "clock": T0 + 100, "cloud": cloud,
        "guild": False, "oldSecrets": list(old),
        "meta": {"name": name, "rev": T0, "editor": "Will-Realm"},
        "members": members or {"Will-Realm": {"name": "Will-Realm", "role": "owner", "rev": T0,
                                              "editor": "Will-Realm", "removed": False}},
        "notes": {n["id"]: n for n in notes},
        "sync": {},
    }


def make_install(root: Path, boards_by_account: dict, product="_classic_beta_", flavour="wow_classic_beta"):
    """A fake WoW root with Corkboard installed and SavedVariables per account."""
    folder = root / product
    (folder / "Interface" / "AddOns" / "Corkboard").mkdir(parents=True, exist_ok=True)
    (folder / "Interface" / "AddOns" / "Corkboard_Cloud").mkdir(parents=True, exist_ok=True)
    (folder / ".flavor.info").write_text(f"Product Flavor!STRING:0\n{flavour}\n")
    for account, boards in boards_by_account.items():
        sv = folder / "WTF" / "Account" / account / "SavedVariables"
        sv.mkdir(parents=True, exist_ok=True)
        db = {"global": {"boards": {b["id"]: b for b in boards}}, "profileKeys": {"Will - Realm": "Will - Realm"}}
        (sv / "Corkboard.lua").write_bytes(luadata.dumps("CorkboardDB", db))
    return folder


def snapshot(root: Path) -> dict:
    return {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
