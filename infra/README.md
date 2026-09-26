# Deploying the sync API (docs/design.md §8)

The stack is `compose.yaml`: the API container from GHCR, Caddy for TLS on the public name, and a daily SQLite backup. Deploy it as an Arcane project on the host.

## Once

1. **DNS:** an A (or CNAME) record for `corkboard.<domain>` pointing at the host's public IP. If the host is behind CGNAT, use a Cloudflare Tunnel instead of Caddy's public ports (§8; still an open question, §14 Q2).
2. **Caddyfile:** replace `corkboard.example.com` with the real name. If the host already runs a reverse proxy on 80/443 (§14 Q1), drop the `caddy` service and route the name to `api:8000` there instead.
3. **Image:** tag a release (`git tag api-v0.1.0 && git push --tags`). `.github/workflows/api-image.yml` builds `ghcr.io/<owner>/corkboard-api` and pushes `:<version>` and `:latest`. Make the package public, or give the host a GHCR pull token.
4. **Arcane:** create a project from this folder with `OWNER=<GitHub owner>` and `TAG=<version>` in its environment, and deploy it.

## Checks (§12 Phase 5)

- From outside the tailnet: `curl -fsS https://corkboard.<domain>/v1/health` returns `{"ok":true}` over valid TLS.
- `curl -m 5 http://<host public IP>:<arcane port>` fails: the dashboard stays tailnet-only. Only 80 and 443 are published.
- Wrong secret, rotation and rate limits: `api/tests/test_api.py` covers them; to spot-check live, a `POST /v1/boards/<id>/sync` with a wrong token returns 401.

## Backups and the restore drill

The `backup` service writes `/data/backup-<Mon..Sun>.db` once a day into the data volume, so there are 7 rolling snapshots.

To drill a restore (§12 Phase 5):

1. Copy yesterday's snapshot out: `docker compose cp api:/data/backup-<Day>.db ./restore.db`.
2. Start a scratch stack with that file as `/data/corkboard.db` (a second project, no public ports).
3. For a board you're a member of, compare `GET /v1/boards/<id>/digest` on both stacks, with the board's token. The scratch stack's digest must match the live one's as of the snapshot; `python3 -m corkboard_api.tools digest restore.db` prints every board's digest offline.
