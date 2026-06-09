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

- **Mode A — direct from anchore (default):** the agent fetches `grype.anchore.io`
  through the egress proxy and pushes to the local repo. Requires the **agent** to
  have egress (via `EGRESS_PROXY`).
- **Mode B — promote from a remote repo:** point `GRYPE_DB_SOURCE_URL` at your
  Artifactory **remote** repo (e.g. `.../grype-db-remote/v6/latest.json`) and set
  `GRYPE_DB_SOURCE_AUTH=1`. The agent then does a purely-internal
  Artifactory→Artifactory promotion (remote → local) and **never egresses** — only
  Artifactory reaches the internet. Use this when build agents are fully air-gapped.

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

Point Grype at the Artifactory repo — note the base ends at `…/<repo>/databases`
(Grype appends `/v6/latest.json` itself):

```bash
export GRYPE_DB_UPDATE_URL="https://<user>:<token>@artifactory.example.com/artifactory/grype-db-local/databases"
grype <image>            # pulls the DB from Artifactory, no internet needed
```

For fully offline scans, pre-populate the DB cache and set
`GRYPE_DB_AUTO_UPDATE=false`.
