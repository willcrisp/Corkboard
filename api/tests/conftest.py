import pytest
from fastapi.testclient import TestClient

from corkboard_api.app import create_app
from corkboard_api.config import Settings

BOARD = "k3f9x2m7q1pz8c4w"
SECRET = "a1b2c3d4e5f6g7h8i9j0k1l2"
T0 = 1790000000


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def make_client(tmp_path, clock):
    clients = []

    def make(**overrides):
        settings = Settings(**({"db": str(tmp_path / "cork.db")} | overrides))
        client = TestClient(create_app(settings, clock=clock))
        client.__enter__()
        clients.append(client)
        return client

    yield make
    for client in clients:
        client.__exit__(None, None, None)


@pytest.fixture
def api(make_client):
    return make_client()


def auth(board=BOARD, secret=SECRET):
    return {"Authorization": f"Bearer {board}.{secret}"}


def note(i, rev=T0 + 1, text=None, editor="Bob-Realm", deleted=False):
    return {"id": f"a1b2c3d4-{i:04d}", "author": "Will-Realm", "created": T0, "rev": rev, "editor": editor,
            "text": "" if deleted else (text if text is not None else f"note {i}"), "color": 1, "deleted": deleted}


@pytest.fixture
def board(api):
    assert api.post("/v1/boards", json={"id": BOARD, "secret": SECRET}).status_code == 201
    return BOARD
