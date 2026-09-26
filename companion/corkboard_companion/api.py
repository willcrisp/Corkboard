"""A small client for the sync API (docs/design.md §7.3), on urllib so the
packaged companion needs no third-party modules."""

from __future__ import annotations

import json
import urllib.error
import urllib.request

USER_AGENT = "Corkboard-Companion/0.1"


class ApiError(Exception):
    def __init__(self, status: int, error: str):
        super().__init__(f"{status} {error}")
        self.status, self.error = status, error


class Api:
    def __init__(self, base_url: str, timeout: float = 20, opener=None):
        self.base = base_url.rstrip("/")
        self.timeout = timeout
        self.opener = opener or urllib.request.build_opener()

    def request(self, method: str, path: str, body: dict | None = None, token: str | None = None) -> dict:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8", "surrogateescape") if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("User-Agent", USER_AGENT)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", "Bearer " + token)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                error = json.loads(e.read() or b"{}").get("error", "")
            except ValueError:
                error = ""
            raise ApiError(e.code, error) from None

    def health(self) -> bool:
        return self.request("GET", "/v1/health").get("ok") is True

    def register(self, board_id: str, secret: str) -> dict:
        return self.request("POST", "/v1/boards", {"id": board_id, "secret": secret})

    def sync(self, board_id: str, secret: str, cursor: int, notes: list, members: list, meta) -> dict:
        return self.request("POST", f"/v1/boards/{board_id}/sync",
                            {"cursor": cursor, "notes": notes, "members": members, "meta": meta},
                            token=f"{board_id}.{secret}")

    def rotate(self, board_id: str, old: str, new: str) -> dict:
        return self.request("POST", f"/v1/boards/{board_id}/rotate", {"secret": new}, token=f"{board_id}.{old}")
