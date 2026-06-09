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

The `databases/v6/` layout is preserved so the relative `path` inside
`latest.json` resolves correctly on the client side.

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
| `GRYPE_DB_SOURCE_AUTH` | — | `0` | `1` = send Artifactory auth on the source fetch (mode B) |
| `GRYPE_DB_SUBPATH` | — | `databases/v6` | path inside the repo |
| `DRY_RUN` | — | `0` | `1` = download + verify, no upload |

### Source modes

There are two ways the job can obtain the DB. Pick one; both push to the same
local repo. In the examples below, replace only the values marked `← replace`;
everything else (including `/artifactory`, the repo names, and `/v6/latest.json`)
is literal — type it exactly.

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
GRYPE_DB_SOURCE_URL=https://artifactory.example.com/artifactory/grype-db-remote/v6/latest.json   # ← replace HOST only
GRYPE_DB_SOURCE_AUTH=1                               # log in to the source with the creds above
```

In `GRYPE_DB_SOURCE_URL`, only the hostname is yours; `/artifactory`,
`/grype-db-remote` (your remote repo name), and `/v6/latest.json` are literal.
`GRYPE_DB_SOURCE_AUTH=1` makes the job send `ARTIFACTORY_USER`/`ARTIFACTORY_TOKEN`
on that fetch — do **not** put credentials in the URL.

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
| `GRYPE_DB_SOURCE_URL` (Mode B) | `/grype-db-remote/v6/latest.json` | the **sync job** |
| `GRYPE_DB_UPDATE_URL` (client) | `/grype-db-local/databases` | the **scanner** |
