# grype-db-artifactory-sync

Environment-agnostic nightly job that mirrors the **Grype v6 vulnerability
database** from `grype.anchore.io` into an **Artifactory generic local
repository**, so air-gapped Grype clients can pull it from Artifactory instead
of reaching the internet.

One portable script (`scripts/sync-grype-db.sh`); GitLab CI and Bamboo are thin
wrappers that both call it. Import into any environment that has Artifactory —
all configuration is via environment variables.

## How it works

```
grype.anchore.io ──(via forward proxy)──▶ this job ──(upload)──▶ Artifactory
   /databases/v6/latest.json                                     <repo>/databases/v6/latest.json
   /databases/v6/<db>.tar.zst                                    <repo>/databases/v6/<db>.tar.zst
```

1. Fetch `latest.json`, read the archive `path` + `checksum`.
2. If that archive already exists in Artifactory with a matching sha256 → **skip**.
3. Download the archive (through the proxy), **verify the sha256**.
4. Upload the archive, then upload `latest.json` **last** (so clients never see a
   pointer to a missing file).

The source URL's path layout (`databases/v6/`) is mirrored into the local repo,
and the remote repo proxies anchore from its **root** — so local and remote
repos share identical object paths, and the relative `path` inside
`latest.json` resolves correctly on the client side.

## Set up the Artifactory repositories (one-time)

Do this once in the JFrog UI before editing `.env`. You need the **local** repo
always; the **remote** repo only if you want Mode B (agents that never egress).

Throughout, replace `artifactory.example.com` with your JFrog hostname. The repo
keys (`grype-db-local`, `grype-db-remote`) are names *you* choose — if you change
them, use the same names in `.env`.

### Step 1 — Local repo (required): where the DB is published

1. Log in to JFrog as an admin.
2. Go to **Administration** (the gear / "admin" switch) → **Repositories**.
3. Click **Create a Repository** → choose **Local**.
4. Pick package type **Generic**.
5. **Repository Key:** type `grype-db-local`.
6. Click **Create Local Repository**.

→ In `.env`: `ARTIFACTORY_REPO=grype-db-local`

This is also the repo your **scanners** read from:
`GRYPE_DB_UPDATE_URL=https://USER:TOKEN@artifactory.example.com/artifactory/grype-db-local/databases`

### Step 2 — Remote repo (Mode B only): proxies anchore so agents don't egress

Skip this if you're using Mode A (agents fetch anchore directly via a proxy).

1. **Administration** → **Repositories** → **Create a Repository** → choose **Remote**.
2. Pick package type **Generic**.
3. **Repository Key:** type `grype-db-remote`.
4. **URL:** type exactly `https://grype.anchore.io`
   (the bare host — no `/databases`, no `/v6`. The remote repo mirrors anchore's
   full path layout, so object paths are identical in the remote and local repos:
   both serve `databases/v6/latest.json`).
5. If your Artifactory reaches the internet through a forward proxy (Squid /
   enterprise), open the **Advanced** tab and set **Proxy** to that proxy (create it
   first — see Step 3). If Artifactory has direct internet, leave Proxy blank.
6. Click **Create Remote Repository**.
7. **Ignore a failing "Test" button.** Test does a GET on the bare
   `https://grype.anchore.io` root, which anchore returns 403/404 for
   even when everything is correct. It is not a real check — verify with Step 4 instead.

→ In `.env`:
`GRYPE_DB_SOURCE_URL=https://artifactory.example.com/artifactory/grype-db-remote/databases/v6/latest.json`
(here `/databases/v6/latest.json` **is** included — that's the object path, not the
repo URL, and it matches the local repo's layout exactly).

### Step 3 — Forward proxy entry (only if Artifactory egresses via a proxy)

Needed only if you set a Proxy in Step 2.5.

1. **Administration** → **Proxies** → **New Proxy**.
2. **Proxy Key:** `squid` (any name). **Host:** your proxy IP/host. **Port:** e.g. `3128`.
3. **Save.** Then go back to the remote repo's Advanced tab and select this proxy.

### Step 4 — Verify (the real test)

Fetch an actual object, not the directory. From any host that can reach Artifactory:

```bash
curl -u USER:TOKEN https://artifactory.example.com/artifactory/grype-db-remote/databases/v6/latest.json
```

A small JSON blob (with `"schemaVersion"` and a `"path"`) = working. A 404 means the
repo key or URL is wrong; a 401 means bad credentials.

### Field → `.env` cheat-sheet

| JFrog UI you entered | `.env` variable |
|---|---|
| your JFrog hostname | inside `ARTIFACTORY_URL=https://...` |
| Local repo key `grype-db-local` | `ARTIFACTORY_REPO=grype-db-local` |
| Remote repo key `grype-db-remote` | the repo segment of `GRYPE_DB_SOURCE_URL` |
| Remote URL `https://grype.anchore.io` | (fixed — nothing to copy) |
| an Artifactory user + access token | `ARTIFACTORY_USER` + `ARTIFACTORY_TOKEN` |

## Configuration (environment variables)

| Variable | Required | Default | Notes |
|---|---|---|---|
| `ARTIFACTORY_URL` | ✅ | — | `https://artifactory.example.com` |
| `ARTIFACTORY_REPO` | ✅ | — | generic **local** repo, e.g. `grype-db-local` |
| `ARTIFACTORY_USER` | ✅ | — | upload user / service account |
| `ARTIFACTORY_TOKEN` | ✅ | — | password or access token (secret) |
| `EGRESS_PROXY` *(CI)* | — | — | forward proxy for the anchore fetch; exported to `HTTPS_PROXY` inside the job |
| `NO_PROXY` | — | — | internal hosts that must bypass the proxy (Artifactory) |
| `GRYPE_DB_SOURCE_URL` | — | `https://grype.anchore.io/databases/v6/latest.json` | upstream listing (see source modes) |
| `GRYPE_DB_SOURCE_AUTH` | — | `auto` | `auto` / `true` / `false`. `auto` = authenticate the source fetch only when its host equals `ARTIFACTORY_URL`. Normally leave unset. |
| `GRYPE_DB_SUBPATH` | — | *derived* | defaults to **mirroring the source URL's path** (e.g. `databases/v6`), with any `artifactory/<repo>/` prefix stripped. Set only to force a non-standard layout. |
| `DRY_RUN` | — | `0` | `1` = download + verify, no upload |

### Source modes

There are two ways the job can obtain the DB. Pick one; both push to the same
local repo. In the examples below, replace only the values marked `← replace`;
everything else (including `/artifactory`, the repo names, and
`/databases/v6/latest.json`) is literal — type it exactly.

**Mode A — direct from anchore (default).** The agent fetches the public anchore
CDN through the egress proxy. Requires the *agent* to have egress (`EGRESS_PROXY`).

```bash
ARTIFACTORY_URL=https://artifactory.example.com   # ← replace (your Artifactory)
ARTIFACTORY_REPO=grype-db-local
ARTIFACTORY_USER=svc-grype                         # ← replace
ARTIFACTORY_TOKEN=your-artifactory-token           # ← replace
# GRYPE_DB_SOURCE_URL and GRYPE_DB_SOURCE_AUTH are left at their defaults.
```

**Mode B — promote from a remote repo.** The agent pulls the DB from your
Artifactory *remote* repo (the one that proxies anchore) and re-publishes it to the
*local* repo — entirely inside Artifactory. The **agent never reaches the
internet**; only Artifactory does. Use this when build agents are fully air-gapped.

```bash
ARTIFACTORY_URL=https://artifactory.example.com    # ← replace (your Artifactory)
ARTIFACTORY_REPO=grype-db-local                     # the LOCAL repo to publish into
ARTIFACTORY_USER=svc-grype                          # ← replace
ARTIFACTORY_TOKEN=your-artifactory-token            # ← replace
GRYPE_DB_SOURCE_URL=https://artifactory.example.com/artifactory/grype-db-remote/databases/v6/latest.json   # ← replace HOST only
```

That's the whole Mode B config — no extra flags. In `GRYPE_DB_SOURCE_URL`, only the
hostname is yours; `/artifactory`, `/grype-db-remote` (your remote repo name), and
`/databases/v6/latest.json` are literal. Because the source host equals `ARTIFACTORY_URL`,
the job **automatically** logs in to the source with `ARTIFACTORY_USER`/`ARTIFACTORY_TOKEN`
(you don't put credentials in the URL, and you don't set any auth flag). The publish
path mirrors the source object path — `databases/v6` — so the local and remote repos
stay path-for-path identical.

Requires `curl`, `jq`, and `sha256sum`/`shasum` on the runner.

## Run locally

```bash
cp .env.example .env      # fill in ARTIFACTORY_* (and proxy if needed)
make test-local           # dry-run: download + verify, no writes
make sync                 # real run: publish to Artifactory
```

## CI

- **GitLab** — `.gitlab-ci.yml`. Add the variables above (mask the token), then
  create a nightly **Schedule** (CI/CD → Schedules). Set the proxy as
  `EGRESS_PROXY`, **not** `HTTPS_PROXY`, so it doesn't break the runner's git clone.
- **Bamboo** — `bamboo-specs/bamboo.yml` (Bamboo Specs YAML v2). Link the repo as a
  Bamboo Specs repository; set `ARTIFACTORY_USER`/`ARTIFACTORY_TOKEN` (secret) as
  plan variables. Trigger is a nightly Quartz cron (`0 0 3 ? * *`).

## Consuming the mirror (Grype client)

This runs wherever you scan (CI job, laptop, scanner host) — it is **not** part of
the sync. Point Grype at the **local** repo. Note the URL ends at `/databases`
(Grype appends `/v6/latest.json` itself — do not add it here):

```bash
export GRYPE_DB_UPDATE_URL="https://svc-grype:your-artifactory-token@artifactory.example.com/artifactory/grype-db-local/databases"
export GRYPE_DB_AUTO_UPDATE=false     # scan time: use the cached DB, never phone home
grype your-image:tag                  # or:  grype dir:/path   |   grype sbom:./sbom.json
```

Replace `svc-grype`, `your-artifactory-token`, and the hostname. Everything else —
`/artifactory`, `grype-db-local`, `/databases` — is literal.

| URL | Ends in | Used by |
|---|---|---|
| `GRYPE_DB_SOURCE_URL` (Mode B) | `/grype-db-remote/databases/v6/latest.json` | the **sync job** |
| `GRYPE_DB_UPDATE_URL` (client) | `/grype-db-local/databases` | the **scanner** |
