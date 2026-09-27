# Deploying the sync API (docs/design.md §8)

The stack is `compose.yaml`: the API container from GHCR, Caddy for TLS on the public name, and a daily SQLite backup. Deploy it as an Arcane project on the host.

## Once

The `corkboard` project builds its image on the host from the uploaded source, like `ballot`: there's no GHCR package to publish or pull.

1. **DNS:** an A (or CNAME) record for `corkboard.<domain>` pointing at the host's public IP, with ports 80 and 443 forwarded to it. If the host is behind CGNAT, use a Cloudflare Tunnel instead of Caddy's public ports (§8, §14.2).
2. **Create and start it** from a machine on the tailnet (Will's Windows box), with the Arcane API key in the environment only:

   ```powershell
   $env:ARCANE_API_KEY = "<key>"
   python tools/arcane_deploy.py files                          # what gets uploaded
   python tools/arcane_deploy.py create --domain corkboard.<domain>
   ```

   `create` stops before changing anything if a `corkboard` project exists or another container already publishes 80 or 443. In that case, remove the `caddy` service from `compose.yaml`, route `/v1/*` to `api:8000` in the existing proxy and serve `web/public/` for everything else (§14.1). Otherwise it creates the project (compose, `.env` with `CORK_DOMAIN`, and the workspace: `Caddyfile`, `.dockerignore`, `api/`, `shared/python/` and `web/public/`), builds `corkboard-api:latest`, brings the stack up, and waits for `https://corkboard.<domain>/v1/health`.
3. **The web app** is at `https://corkboard.<domain>/` (Caddy serves `web/public/`; `/v1/` goes to the API). Updating it is uploading the changed `web/public/` files; no image build or restart is needed.
4. **Point the companion at it:** `corkboard-companion setup --api https://corkboard.<domain>`, then `watch`.

The data lives on the `corkboard-data` volume. Never bring the stack up with `recreateVolumes: true`, and never destroy the project or delete that volume. For a later code deploy, follow the `ballot` steps (back up the volume, check the workspace hasn't drifted, upload the changed files, build `api`, then `up` with `forceRecreate`).

## Checks (§12 Phase 5)

- From outside the tailnet: `curl -fsS https://corkboard.<domain>/v1/health` returns `{"ok":true}` over valid TLS, and `curl -sI https://corkboard.<domain>/` returns 200 with a `Content-Security-Policy` header (the web app).
- `curl -m 5 http://<host public IP>:<arcane port>` fails: the dashboard stays tailnet-only. Only 80 and 443 are published.
- Wrong secret, rotation and rate limits: `api/tests/test_api.py` covers them; to spot-check live, a `POST /v1/boards/<id>/sync` with a wrong token returns 401.

## Backups and the restore drill

The `backup` service writes `/data/backup-<Mon..Sun>.db` once a day into the data volume, so there are 7 rolling snapshots.

To drill a restore (§12 Phase 5):

1. Copy yesterday's snapshot out: `docker compose cp api:/data/backup-<Day>.db ./restore.db`.
2. Start a scratch stack with that file as `/data/corkboard.db` (a second project, no public ports).
3. For a board you're a member of, compare `GET /v1/boards/<id>/digest` on both stacks, with the board's token. The scratch stack's digest must match the live one's as of the snapshot; `python3 -m corkboard_api.tools digest restore.db` prints every board's digest offline.
