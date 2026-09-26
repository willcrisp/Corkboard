import json
import sys
from email.parser import BytesParser
from email.policy import HTTP
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import arcane_deploy  # noqa: E402


def test_workspace_holds_what_the_image_build_needs_and_no_tests():
    files = arcane_deploy.workspace_files()
    for path in ("Caddyfile", ".dockerignore", "api/Dockerfile", "api/pyproject.toml", "shared/python/pyproject.toml"):
        assert path in files, path
    assert "api/corkboard_api/app.py" in files and "shared/python/corkcore/merge.py" in files
    assert not [p for p in files if "/tests/" in p or p == "compose.yaml"]
    assert not [p for p, data in files.items() if b"\r\n" in data]
    assert b"{$CORK_DOMAIN}" in files["Caddyfile"]


def test_compose_builds_on_the_host_and_names_its_volume():
    text = arcane_deploy.compose()
    assert "name: corkboard\n" in text
    assert "dockerfile: api/Dockerfile" in text and "image: corkboard-api:latest" in text
    assert "ghcr.io" not in text
    assert "name: corkboard-data" in text and "${CORK_DOMAIN:?" in text


def test_create_request_references_every_upload_in_order():
    body, ctype = arcane_deploy.create_request("corkboard.example.com")
    msg = BytesParser(policy=HTTP).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
    parts = list(msg.iter_parts())
    fields = {p.get_param("name", header="content-disposition"): p for p in parts}
    project = json.loads(fields["project"].get_content())
    assert project["name"] == "corkboard"
    assert project["envContent"] == "CORK_DOMAIN=corkboard.example.com\n"
    assert project["composeContent"] == arcane_deploy.compose()

    uploads = [p.get_payload(decode=True) for p in parts if p.get_param("name", header="content-disposition") == "files"]
    changes = json.loads(fields["manifest"].get_content())["fileChanges"]
    files = arcane_deploy.workspace_files()
    assert [c["uploadIndex"] for c in changes] == list(range(len(uploads)))
    for change in changes:
        assert change["operation"] == "create_file"
        assert uploads[change["uploadIndex"]] == files[change["relativePath"]]
