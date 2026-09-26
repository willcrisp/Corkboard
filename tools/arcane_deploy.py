"""Create and start the `corkboard` Arcane project that hosts the sync API
(docs/design.md §8, infra/README.md).

Run it from a machine on the tailnet. The Arcane API key comes from the
ARCANE_API_KEY environment variable and is never written anywhere.

    python tools/arcane_deploy.py files
    python tools/arcane_deploy.py create --domain corkboard.example.com
    python tools/arcane_deploy.py health --domain corkboard.example.com

`create` checks that no `corkboard` project exists and nothing else publishes
ports 80 or 443, then creates the project (compose, .env and the workspace in
one request), builds the API image on the host, brings the stack up and waits
for /v1/health over TLS. It stops at the first step that fails.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARCANE = "https://harry.alpine-ionian.ts.net/api"
ENV = "0"
PROJECT = "corkboard"

# Workspace path -> repo path, besides api/ and shared/python/ (tests left out).
EXTRA = {"Caddyfile": "infra/Caddyfile", ".dockerignore": ".dockerignore"}


def workspace_files() -> dict[str, bytes]:
    """The files uploaded next to compose.yaml, as LF text, keyed by workspace path."""
    tracked = subprocess.run(
        ["git", "ls-files", "api", "shared/python"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.split()
    paths = {p: p for p in tracked if "/tests/" not in p}
    paths.update(EXTRA)
    return {dest: (ROOT / src).read_bytes().replace(b"\r\n", b"\n") for dest, src in sorted(paths.items())}


def compose() -> str:
    return (ROOT / "infra/compose.yaml").read_text().replace("\r\n", "\n")


def multipart(fields: dict[str, str], files: list[tuple[str, bytes]]) -> tuple[bytes, str]:
    """A multipart/form-data body: text fields, then one `files` part per upload, in order."""
    boundary = uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        out.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        out.append(value.encode() + b"\r\n")
    for filename, data in files:
        out.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="files"; filename="{filename}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n".encode()
        )
        out.append(data + b"\r\n")
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def create_request(domain: str) -> tuple[bytes, str]:
    files = workspace_files()
    manifest = {
        "fileChanges": [
            {"operation": "create_file", "relativePath": path, "uploadIndex": i} for i, path in enumerate(files)
        ]
    }
    project = {"name": PROJECT, "composeContent": compose(), "envContent": f"CORK_DOMAIN={domain}\n"}
    return multipart(
        {"project": json.dumps(project), "manifest": json.dumps(manifest)},
        [(Path(p).name, data) for p, data in files.items()],
    )


class Arcane:
    def __init__(self, base: str, key: str):
        self.base, self.key = base.rstrip("/"), key

    def request(self, method: str, path: str, body: bytes | None = None, ctype: str = "application/json"):
        req = urllib.request.Request(self.base + path, data=body, method=method)
        req.add_header("X-API-Key", self.key)
        req.add_header("Accept", "application/json")
        if body is not None:
            req.add_header("Content-Type", ctype)
        try:
            return urllib.request.urlopen(req, timeout=1800)
        except urllib.error.HTTPError as e:
            sys.exit(f"{method} {path} failed: {e.code} {e.read().decode(errors='replace')[:2000]}")

    def json(self, method: str, path: str, payload=None, body: bytes | None = None, ctype: str = "application/json"):
        if payload is not None:
            body = json.dumps(payload).encode()
        with self.request(method, path, body, ctype) as resp:
            return json.load(resp)

    def stream(self, path: str, payload) -> None:
        """POSTs to a streaming operation and echoes it; exits on an error line."""
        with self.request("POST", path, json.dumps(payload).encode()) as resp:
            for raw in resp:
                line = raw.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    print("  " + line)
                    continue
                if isinstance(obj, dict) and obj.get("error"):
                    sys.exit(f"{path} failed: {obj['error']}")
                if isinstance(obj, dict) and obj.get("done"):
                    return
                text = obj.get("message") or obj.get("status") or obj.get("stream") if isinstance(obj, dict) else None
                if text:
                    print("  " + str(text).rstrip())
        sys.exit(f"{path} ended without a done line")


def preflight(api: Arcane, domain: str) -> None:
    names = [p.get("name") for p in api.json("GET", f"/environments/{ENV}/projects?limit=500&archived=all")["data"]]
    if PROJECT in names:
        sys.exit(f"A project named {PROJECT!r} already exists in Arcane; not creating another.")
    clash = []
    for c in api.json("GET", f"/environments/{ENV}/containers?limit=500&includeInternal=true&includeHidden=true")["data"]:
        for port in c.get("ports") or []:
            if port.get("publicPort") in (80, 443):
                clash.append(f"{','.join(c.get('names') or [c.get('id', '?')])} publishes {port['publicPort']}")
    if clash:
        sys.exit(
            "Ports 80/443 are already taken on the host:\n  " + "\n  ".join(sorted(set(clash))) + "\n"
            "Drop the caddy service and route the name to api:8000 in that proxy instead (infra/README.md)."
        )
    try:
        print(f"{domain} resolves to {socket.gethostbyname(domain)}.")
    except OSError:
        print(f"Warning: {domain} doesn't resolve yet. Caddy can't get a certificate until it does.")


def health(domain: str, tries: int = 36) -> None:
    url = f"https://{domain}/v1/health"
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                print(f"{url}: {resp.status} {resp.read().decode()}")
                return
        except (urllib.error.URLError, OSError) as e:
            last = e
        time.sleep(5)
    sys.exit(f"{url} didn't answer after {tries * 5} s: {last}")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arcane", default=ARCANE, help="Arcane API base URL")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("files", help="list the workspace files create would upload")
    c = sub.add_parser("create", help="create, build and start the project")
    c.add_argument("--domain", required=True, help="the public hostname, e.g. corkboard.example.com")
    h = sub.add_parser("health", help="check /v1/health over TLS")
    h.add_argument("--domain", required=True)
    args = ap.parse_args(argv)

    if args.cmd == "files":
        for path, data in workspace_files().items():
            print(f"{len(data):8d}  {path}")
        return
    if args.cmd == "health":
        health(args.domain)
        return

    key = os.environ.get("ARCANE_API_KEY")
    if not key:
        sys.exit("Set ARCANE_API_KEY first.")
    api = Arcane(args.arcane, key)
    preflight(api, args.domain)

    body, ctype = create_request(args.domain)
    created = api.json("POST", f"/environments/{ENV}/projects", body=body, ctype=ctype)["data"]
    pid = created["id"]
    print(f"Created project {created.get('name')} ({pid}) at {created.get('path') or created.get('relativePath')}.")

    print("Building the API image on the host...")
    api.stream(f"/environments/{ENV}/projects/{pid}/build", {"load": True, "services": ["api"]})
    print("Starting the stack...")
    api.stream(
        f"/environments/{ENV}/projects/{pid}/up",
        {"forceRecreate": False, "recreateVolumes": False, "removeOrphans": False, "pullPolicy": "missing"},
    )
    print("Waiting for the API over TLS (Caddy fetches its certificate on first start)...")
    health(args.domain)


if __name__ == "__main__":
    main()
