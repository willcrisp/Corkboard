"""The HTTP surface (docs/design.md §7.3):

    POST /v1/boards                register {id, secret}; 409 if it exists
    POST /v1/boards/{id}/sync      {cursor, notes[], members[], meta} -> merge, then changes since cursor
    POST /v1/boards/{id}/rotate    {secret}: the new secret; auth with the old one
    GET  /v1/boards/{id}/digest    the server's digest, count and cursor (for checks and the backup drill)
    GET  /v1/health                liveness and a database check

With CORK_WEB set, the web app (web/public) is served at / as well, for local
runs. Deployed, Caddy serves it and the API only answers /v1/.

Auth: "Authorization: Bearer <boardId>.<secret>". The server stores
sha256(secret) and compares in constant time. Logs carry the board id,
route, status and latency, never the Authorization header or bodies.
"""

from __future__ import annotations

import json
import logging
import socket
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from corkcore import invite as invites
from corkcore.util import INT_MAX, is_integer

from .config import Settings
from .db import Database
from .limits import RateLimiter

log = logging.getLogger("corkboard.api")


class Problem(Exception):
    def __init__(self, status: int, error: str, headers: dict | None = None):
        self.status, self.error, self.headers = status, error, headers or {}


def create_app(settings: Settings | None = None, clock=time.monotonic) -> FastAPI:
    settings = settings or Settings.from_env()
    state: dict[str, Any] = {}

    @asynccontextmanager
    async def lifespan(_app):
        state["db"] = Database(settings.db)
        try:
            yield
        finally:
            state["db"].close()

    app = FastAPI(title="Corkboard sync API", version="1", lifespan=lifespan, docs_url=None, redoc_url=None,
                  openapi_url=None)
    board_limit = RateLimiter(settings.board_rate, 60, clock)
    register_limit = RateLimiter(settings.register_rate, 3600, clock)
    proxy_ips: set[str] = set()

    def db() -> Database:
        return state["db"]

    def client_ip(request: Request) -> str:
        peer = request.client.host if request.client else "?"
        if settings.trusted_proxy:
            if not proxy_ips:
                try:
                    proxy_ips.update(socket.gethostbyname_ex(settings.trusted_proxy)[2])
                except OSError:
                    proxy_ips.add(settings.trusted_proxy)
            forwarded = request.headers.get("x-forwarded-for")
            if peer in proxy_ips and forwarded:
                return forwarded.split(",")[-1].strip()
        return peer

    async def body(request: Request) -> dict:
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > settings.max_body:
            raise Problem(413, "too_large")
        raw = await request.body()
        if len(raw) > settings.max_body:
            raise Problem(413, "too_large")
        try:
            data = json.loads(raw or b"{}")
        except ValueError:
            raise Problem(400, "bad_json") from None
        if not isinstance(data, dict):
            raise Problem(400, "bad_json")
        return data

    def authorise(request: Request, board_id: str) -> str:
        """Checks the bearer token for this board. Returns the secret."""
        header = request.headers.get("authorization", "")
        scheme, _, token = header.partition(" ")
        token_board, _, secret = token.partition(".")
        if scheme.lower() != "bearer" or token_board != board_id or not secret:
            raise Problem(401, "unauthorised")
        if not board_limit.allow(board_id):
            raise Problem(429, "rate_limited", {"Retry-After": str(board_limit.retry_after(board_id))})
        if not db().check(board_id, secret):
            raise Problem(401, "unauthorised")
        return secret

    @app.exception_handler(Problem)
    async def problem(_request: Request, exc: Problem):
        return JSONResponse({"error": exc.error}, status_code=exc.status, headers=exc.headers)

    @app.middleware("http")
    async def access_log(request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        board = request.path_params.get("board_id", "-") if hasattr(request, "path_params") else "-"
        route = request.scope.get("route")
        log.info("board=%s route=%s status=%d ms=%.1f", board, getattr(route, "path", request.url.path),
                 response.status_code, (time.perf_counter() - start) * 1000)
        return response

    @app.get("/v1/health")
    def health():
        try:
            ok = db().healthy()
        except Exception:  # noqa: BLE001 - any database failure is unhealthy
            ok = False
        return JSONResponse({"ok": ok}, status_code=200 if ok else 503)

    @app.post("/v1/boards", status_code=201)
    async def register(request: Request):
        ip = client_ip(request)
        if not register_limit.allow(ip):
            raise Problem(429, "rate_limited", {"Retry-After": str(register_limit.retry_after(ip))})
        data = await body(request)
        board_id, secret = data.get("id"), data.get("secret")
        if not invites.valid_id(board_id) or not invites.valid_secret(secret):
            raise Problem(400, "bad_board")
        if not db().register(board_id, secret):
            raise Problem(409, "exists")
        return {"id": board_id}

    @app.post("/v1/boards/{board_id}/sync")
    async def sync(board_id: str, request: Request):
        authorise(request, board_id)
        data = await body(request)
        cursor = data.get("cursor", 0)
        notes, members, meta = data.get("notes", []), data.get("members", []), data.get("meta")
        if not is_integer(cursor, 0, INT_MAX) or not isinstance(notes, list) or not isinstance(members, list):
            raise Problem(400, "bad_sync")
        return db().sync(board_id, int(cursor), notes, members, meta, settings.max_notes, settings.page)

    @app.post("/v1/boards/{board_id}/rotate")
    async def rotate(board_id: str, request: Request):
        authorise(request, board_id)
        data = await body(request)
        secret = data.get("secret")
        if not invites.valid_secret(secret):
            raise Problem(400, "bad_secret")
        db().rotate(board_id, secret)
        return {"id": board_id}

    @app.get("/v1/boards/{board_id}/digest")
    def board_digest(board_id: str, request: Request):
        authorise(request, board_id)
        return db().digest(board_id)

    if settings.web:
        app.mount("/", StaticFiles(directory=settings.web, html=True), name="web")

    return app


def main() -> None:  # pragma: no cover - the container's entry point
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    uvicorn.run(create_app(), host="0.0.0.0", port=8000, access_log=False, proxy_headers=False)


if __name__ == "__main__":  # pragma: no cover
    main()
