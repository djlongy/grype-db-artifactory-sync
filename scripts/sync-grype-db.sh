#!/usr/bin/env bash
#
# sync-grype-db.sh — mirror the Grype v6 vulnerability database into an
# Artifactory generic LOCAL repository, preserving the upstream
# databases/v6/ layout so air-gapped Grype clients can pull it with:
#
#     GRYPE_DB_UPDATE_URL=<ARTIFACTORY_URL>/artifactory/<ARTIFACTORY_REPO>/databases
#
# (Grype appends /v6/latest.json itself; the relative archive path inside
# latest.json then resolves against the same Artifactory directory.)
#
# Idempotent: if the current upstream DB already exists in Artifactory with a
# matching sha256, nothing is uploaded — safe to run nightly.
#
# Egress proxy: curl honours HTTPS_PROXY / HTTP_PROXY / NO_PROXY from the
# environment, so set those to route the anchore.io fetch through Squid or an
# enterprise forward proxy. Artifactory uploads honour NO_PROXY for internal
# hosts.
#
# Configuration — ALL via environment (see .env.example):
#   ARTIFACTORY_URL      required  e.g. https://artifactory.example.com
#   ARTIFACTORY_REPO     required  generic local repo, e.g. grype-db-local
#   ARTIFACTORY_USER     required  upload user / service account
#   ARTIFACTORY_TOKEN    required  password or access token (keep secret)
#   GRYPE_DB_SOURCE_URL  optional  default https://grype.anchore.io/databases/v6/latest.json
#   GRYPE_DB_SUBPATH     optional  default databases/v6
#   DRY_RUN              optional  set to 1 to download+verify but skip upload
#
# Requires: curl, jq, and sha256sum (Linux) or shasum (macOS).
#
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $1" >&2; exit 3; }; }
need curl
need jq
if   command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum    >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | awk '{print $1}'; }
else echo "ERROR: need sha256sum or shasum" >&2; exit 3; fi

: "${ARTIFACTORY_URL:?set ARTIFACTORY_URL (e.g. https://artifactory.example.com)}"
: "${ARTIFACTORY_REPO:?set ARTIFACTORY_REPO (generic local repo, e.g. grype-db-local)}"
: "${ARTIFACTORY_USER:?set ARTIFACTORY_USER}"
: "${ARTIFACTORY_TOKEN:?set ARTIFACTORY_TOKEN}"
SOURCE_URL="${GRYPE_DB_SOURCE_URL:-https://grype.anchore.io/databases/v6/latest.json}"
SUBPATH="${GRYPE_DB_SUBPATH:-databases/v6}"

ART_BASE="${ARTIFACTORY_URL%/}/artifactory"
DEST_DIR="${ART_BASE}/${ARTIFACTORY_REPO}/${SUBPATH}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# Shared curl flags. Auth is passed only on Artifactory calls, never upstream.
C=(curl -sS --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 900)
A=(-u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}")

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

log "Grype DB → Artifactory sync"
log "  source: ${SOURCE_URL}"
log "  dest:   ${DEST_DIR}/"

# 1) Fetch the upstream listing (through the egress proxy, if set).
"${C[@]}" -f "${SOURCE_URL}" -o "${tmp}/latest.json"
db_path="$(jq -r '.path' "${tmp}/latest.json")"
want="$(jq -r '.checksum' "${tmp}/latest.json")"; want="${want#sha256:}"
[ -n "${db_path}" ] && [ "${db_path}" != "null" ] || { echo "ERROR: listing has no .path" >&2; exit 1; }
[ -n "${want}" ]    && [ "${want}"    != "null" ] || { echo "ERROR: listing has no .checksum" >&2; exit 1; }
log "  db:     ${db_path}"
log "  sha256: ${want}"

# 2) Idempotency — already present in Artifactory with a matching checksum?
have="$("${C[@]}" "${A[@]}" "${ART_BASE}/api/storage/${ARTIFACTORY_REPO}/${SUBPATH}/${db_path}" 2>/dev/null \
        | jq -r '.checksums.sha256 // empty' 2>/dev/null || true)"
if [ "${have}" = "${want}" ]; then
  log "✓ up-to-date — ${db_path} already published (sha256 match); nothing to do"
  exit 0
fi

# 3) Download the archive (through the egress proxy) and verify its checksum.
log "→ downloading archive"
"${C[@]}" -f "${SOURCE_URL%/*}/${db_path}" -o "${tmp}/${db_path}"
got="$(sha "${tmp}/${db_path}")"
[ "${got}" = "${want}" ] || { echo "ERROR: checksum mismatch (want ${want}, got ${got})" >&2; exit 1; }
log "✓ checksum verified"

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN=1 — verified but not uploading"
  exit 0
fi

# 4) Upload the ARCHIVE first, then latest.json LAST — so a client never sees a
#    latest.json pointing at an archive that isn't there yet.
log "→ uploading archive"
"${C[@]}" -f "${A[@]}" -H "X-Checksum-Sha256: ${want}" \
  -T "${tmp}/${db_path}" "${DEST_DIR}/${db_path}" -o /dev/null
log "→ uploading latest.json"
"${C[@]}" -f "${A[@]}" -T "${tmp}/latest.json" "${DEST_DIR}/latest.json" -o /dev/null

log "✓ sync complete — ${db_path} (+ latest.json) published to ${ARTIFACTORY_REPO}/${SUBPATH}/"
