# Arcane: next steps for hosting the sync API

Written 2026-09-26. The `corkboard` Arcane project doesn't exist yet. Everything needed to create it is on branch `claude/youthful-mendel-ys9hft` (commit `46bcff6`), not yet on `main`.

## Why it has to run from Will's box

Arcane's API (`https://harry.alpine-ionian.ts.net/api`) is tailnet-only. Cloud sessions aren't on the tailnet, so they can't reach it, and no network setting changes that. Run the deploy from Will's Windows box, which is on the tailnet.

## What's ready

- **`infra/compose.yaml`:** the `corkboard` project, set up like `ballot`. Arcane builds `corkboard-api:latest` on the host from the uploaded source (no GHCR). The stack is the API, Caddy for TLS, and a daily SQLite backup. Data lives on the named volume `corkboard-data`.
- **`infra/Caddyfile`:** reads the hostname from `CORK_DOMAIN` in the project's `.env`, so it needs no hand edit.
- **`tools/arcane_deploy.py`:** Python standard library only. Its endpoints and payloads follow Arcane v2.13.1's source and match the `ballot` notes (`X-API-Key` header, environment `0`). `create` does this, stopping at the first failure:
  1. Refuses if a `corkboard` project already exists, or another container already publishes port 80 or 443.
  2. Creates the project in one request: `compose.yaml`, `.env` with `CORK_DOMAIN`, and the workspace (`Caddyfile`, `.dockerignore`, `api/`, `shared/python/`).
  3. Builds the `api` service, brings the stack up, and waits for `https://<domain>/v1/health`.

**Tested so far:** only offline. The multipart request round-trips, and the exact upload set pip-installs and answers `/v1/health`. It has never run against Arcane, and the Docker image hasn't been built outside CI.

## Before running it

1. **Pick the domain**, for example `corkboard.<yourdomain>`.
2. **DNS:** an A (or CNAME) record for it, pointing at the host's public IP.
3. **Ports:** forward 80 and 443 to the host. Caddy can't get a certificate until DNS and both ports work. Behind CGNAT, use a Cloudflare Tunnel instead (design.md §8, §14.2).

## Run it

On Will's box, with the key in the environment only (never in a file or commit):

```powershell
git pull
git checkout claude/youthful-mendel-ys9hft
$env:ARCANE_API_KEY = "<key>"
python tools/arcane_deploy.py files                          # lists what gets uploaded
python tools/arcane_deploy.py create --domain corkboard.<yourdomain>
```

If DNS or the certificate is slow, recheck later with:

```powershell
python tools/arcane_deploy.py health --domain corkboard.<yourdomain>
```

## If `create` stops

- **"Ports 80/443 are already taken":** the host already runs a web server. Remove the `caddy` service from `infra/compose.yaml` and add a route for the domain to `api:8000` in that server instead (design.md §14.1). Ask a session to make that change.
- **"A project named 'corkboard' already exists":** a previous run got part-way. Look at it in Arcane before doing anything else. Don't destroy it if it might hold data.
- **Build or up failed:** the error line from Arcane is printed. The project exists at that point, so fix the cause and retry the build and up from Arcane's UI rather than running `create` again.

## After it's up

1. **Point the companion at it:** `corkboard-companion setup --api https://corkboard.<yourdomain>`, then `corkboard-companion watch`.
2. **Phase 5 checks** (design.md §12, `infra/README.md`): health over TLS from outside the tailnet, the Arcane dashboard unreachable from the internet, and a restore drill.
3. **The two-player test:** a second client on the same board edits and logs out, your companion syncs, and after your `/reload` their edits are there.
4. **Rotate the Arcane API key.** It was pasted into a chat session on 2026-09-26.
5. **Merge the branch to `main`** once the deploy works.

## Rules for later deploys

- Data lives on the `corkboard-data` volume. Never bring the stack up with `recreateVolumes: true`, and never destroy the project or delete that volume.
- For code changes, follow the `ballot` procedure:
  1. Back up the volume and download the backup.
  2. Check the workspace hasn't drifted from what was last deployed.
  3. Upload the changed files with baselines.
  4. Build `api`.
  5. `up` with `forceRecreate: true`, `recreateVolumes: false`.
  6. Verify against the backup.
