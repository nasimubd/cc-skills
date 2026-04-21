#!/usr/bin/env bash
# upload.sh — Phase 4 of the chronicle-share pipeline.
#
# Upload the Phase 3 artifact (chronicle-share.tar.gz) to Cloudflare R2, then
# emit a 7-day presigned URL and record the upload metadata in manifest.json.
#
# Credentials come from 1Password (item: "R2 Chronicle Share", Personal vault).
# They're loaded into shell-local variables for a single `aws` invocation and
# never exported, logged, or written to disk.
#
# Input contract (produced by Phase 3, archive.sh):
#   $STAGING/manifest.json               archived=true, uploaded=false
#   $STAGING/chronicle-share.tar.gz       the artifact to upload
#   $STAGING/chronicle-share.tar.gz.sha256 sidecar (verified pre-upload)
#
# Output:
#   R2 object: s3://<bucket>/<prefix>/<project_encoded>/<ts>-<short_sha>.tar.gz
#   $STAGING/manifest.json mutated: uploaded=true + upload.*
#   stdout: the presigned URL (so the pipeline can be chained / piped)
#
# Usage:
#   upload.sh [--dry-run] [--expires-in SECONDS] [--key-prefix PATH] [--force] STAGING_DIR
#   upload.sh --help
#
# Exit codes:
#   0  upload complete
#   1  usage / validation error
#   2  1Password credential fetch failed
#   3  R2 upload or presign failed

set -euo pipefail

STAGING=""
DRY_RUN=0
FORCE=0
EXPIRES_IN=604800          # 7 days — matches Terry's convention
KEY_PREFIX="chronicles"

OP_ACCOUNT="E37RVJRKWZAVFEXY6X2VA4PBWA"
OP_ITEM_REF="op://Personal/R2 Chronicle Share"

log() { printf '[upload] %s\n' "$*" >&2; }
err() { printf '[upload] ERROR: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: upload.sh [OPTIONS] STAGING_DIR

Upload the Phase 3 archive to Cloudflare R2 and emit a 7-day presigned URL.

Options:
  --dry-run               Validate + load creds + print the plan, DO NOT upload.
  --expires-in SECONDS    Presigned URL TTL (default: 604800 = 7 days).
  --key-prefix PATH       Override default object key prefix (default: chronicles).
  --force                 Bypass the uploaded=true idempotency guard.
  --help, -h              Show this help.

Credentials come from 1Password item "R2 Chronicle Share" (Personal vault).
You must be signed in: `op signin` or `op signin --account=<id>`.

After success:
  - R2 object: s3://<bucket>/<key>
  - manifest.json mutated: uploaded=true + upload.* subfield
  - stdout: the presigned URL (Phase 5 orchestrator + Phase 6 Telegram post)

Object key scheme:
  <prefix>/<project_encoded>/<ts>-<short_sha>.tar.gz
  e.g.  chronicles/-Users-mdnasim-eon-cc-skills/2026-04-21T11-26-08Z-9f89ba19.tar.gz

Idempotency: refuses if manifest.uploaded is already true. Pass --force to
re-upload (generates a new presigned URL, overwrites the R2 object).
EOF
}

# --- arg parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --force)       FORCE=1; shift ;;
    --expires-in)  EXPIRES_IN="${2:?--expires-in requires SECONDS}"; shift 2 ;;
    --key-prefix)  KEY_PREFIX="${2:?--key-prefix requires a path}"; shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    --*)           err "unknown arg: $1"; usage >&2; exit 1 ;;
    *)
      if [[ -n "$STAGING" ]]; then
        err "only one STAGING_DIR allowed (got '$STAGING' and '$1')"
        exit 1
      fi
      STAGING="$1"; shift ;;
  esac
done

if [[ -z "$STAGING" ]]; then
  err "STAGING_DIR required"
  usage >&2
  exit 1
fi

if ! [[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] || [[ "$EXPIRES_IN" -lt 1 ]]; then
  err "--expires-in must be a positive integer (got: $EXPIRES_IN)"
  exit 1
fi

# R2 / S3 API caps presigned URL expiry at 7 days (604800s).
if [[ "$EXPIRES_IN" -gt 604800 ]]; then
  err "--expires-in max is 604800 (7 days); got $EXPIRES_IN"
  exit 1
fi

# --- validate deps ----------------------------------------------------------
for bin in op aws jq shasum stat date; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "required tool not on PATH: $bin"
    exit 1
  fi
done

# --- validate staging -------------------------------------------------------
if [[ ! -d "$STAGING" ]]; then
  err "staging dir not found: $STAGING"
  exit 1
fi

STAGING="$(cd "$STAGING" && pwd)"
manifest="$STAGING/manifest.json"
archive="$STAGING/chronicle-share.tar.gz"
sidecar="$archive.sha256"

if [[ ! -f "$manifest" ]]; then
  err "manifest.json not found: $manifest"
  exit 1
fi

if ! jq -e . "$manifest" >/dev/null 2>&1; then
  err "manifest.json is not valid JSON"
  exit 1
fi

if [[ ! -f "$archive" ]]; then
  err "archive not found: $archive — run archive.sh first"
  exit 1
fi

if [[ ! -f "$sidecar" ]]; then
  err "sidecar not found: $sidecar — run archive.sh first"
  exit 1
fi

# --- guard: must be archived -----------------------------------------------
is_archived="$(jq -r '.archived // false' "$manifest")"
if [[ "$is_archived" != "true" ]]; then
  err "manifest.archived is not true — run archive.sh first"
  exit 1
fi

# --- guard: idempotency ----------------------------------------------------
is_uploaded="$(jq -r '.uploaded // false' "$manifest")"
if [[ "$is_uploaded" == "true" && "$FORCE" -ne 1 ]]; then
  err "manifest.uploaded is already true — refusing to re-upload"
  err "  pass --force to override (new presigned URL will be generated)"
  exit 1
fi

# --- verify archive integrity via sidecar before uploading ------------------
if ! (cd "$STAGING" && shasum -a 256 -c chronicle-share.tar.gz.sha256 >/dev/null 2>&1); then
  err "sidecar SHA-256 check failed — archive is corrupt or out of sync"
  err "  re-run archive.sh --force on this staging dir"
  exit 1
fi

# --- compute object key from manifest ---------------------------------------
project_encoded="$(jq -r '.source.project_encoded' "$manifest")"
archive_sha="$(jq -r '.archive.sha256' "$manifest")"
archive_created="$(jq -r '.archive.created_at_utc' "$manifest")"

if [[ -z "$project_encoded" || "$project_encoded" == "null" ]]; then
  err "manifest.source.project_encoded is missing"
  exit 1
fi
if [[ -z "$archive_sha" || "$archive_sha" == "null" ]]; then
  err "manifest.archive.sha256 is missing"
  exit 1
fi
if [[ -z "$archive_created" || "$archive_created" == "null" ]]; then
  err "manifest.archive.created_at_utc is missing"
  exit 1
fi

short_sha="${archive_sha:0:8}"
# Replace ':' with '-' for URL-safe object keys.
ts="${archive_created//:/-}"
object_key="${KEY_PREFIX}/${project_encoded}/${ts}-${short_sha}.tar.gz"

# --- load creds from 1Password ---------------------------------------------
log "loading credentials from 1Password (item: R2 Chronicle Share)"

set +e
R2_ACCESS_KEY="$(op read "$OP_ITEM_REF/username"     --account="$OP_ACCOUNT" 2>/dev/null)"; rc1=$?
R2_SECRET_KEY="$(op read "$OP_ITEM_REF/credential"   --account="$OP_ACCOUNT" 2>/dev/null)"; rc2=$?
R2_ENDPOINT="$(  op read "$OP_ITEM_REF/endpoint_url" --account="$OP_ACCOUNT" 2>/dev/null)"; rc3=$?
R2_BUCKET="$(    op read "$OP_ITEM_REF/bucket_name"  --account="$OP_ACCOUNT" 2>/dev/null)"; rc4=$?
set -e

if [[ "$rc1" -ne 0 || "$rc2" -ne 0 || "$rc3" -ne 0 || "$rc4" -ne 0 ]]; then
  err "failed to read R2 credentials from 1Password"
  err "  ensure you're signed in: op signin --account=$OP_ACCOUNT"
  exit 2
fi

if [[ -z "$R2_ACCESS_KEY" || -z "$R2_SECRET_KEY" || -z "$R2_ENDPOINT" || -z "$R2_BUCKET" ]]; then
  err "one or more credential fields is empty"
  exit 2
fi

# --- summarize plan ---------------------------------------------------------
archive_size="$(stat -f %z "$archive")"

log "staging     : $STAGING"
log "archive     : $archive ($archive_size bytes)"
log "bucket      : $R2_BUCKET"
log "key         : $object_key"
log "endpoint    : $R2_ENDPOINT"
log "expires_in  : $EXPIRES_IN sec"

# --- dry-run short-circuit --------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN — would run:"
  log "  aws s3 cp $archive s3://$R2_BUCKET/$object_key --endpoint-url $R2_ENDPOINT"
  log "  aws s3 presign s3://$R2_BUCKET/$object_key --endpoint-url $R2_ENDPOINT --expires-in $EXPIRES_IN"
  log "DRY-RUN — no changes made; manifest unchanged"
  exit 0
fi

# --- upload -----------------------------------------------------------------
log "uploading to R2..."
uploaded_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY" \
     AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY" \
     AWS_DEFAULT_REGION=auto \
     aws s3 cp "$archive" "s3://$R2_BUCKET/$object_key" \
       --endpoint-url "$R2_ENDPOINT" >&2; then
  err "aws s3 cp failed"
  exit 3
fi

# --- presign ----------------------------------------------------------------
log "generating presigned URL (expires in $EXPIRES_IN sec)..."
set +e
presigned_url="$(
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY" \
  AWS_DEFAULT_REGION=auto \
  aws s3 presign "s3://$R2_BUCKET/$object_key" \
    --endpoint-url "$R2_ENDPOINT" \
    --expires-in "$EXPIRES_IN" 2>/dev/null
)"
rc=$?
set -e

if [[ "$rc" -ne 0 || -z "$presigned_url" ]]; then
  err "aws s3 presign failed"
  exit 3
fi

# --- compute expiry timestamp (uploaded_at + EXPIRES_IN) --------------------
uploaded_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$uploaded_at_utc" +%s)"
expires_epoch=$(( uploaded_epoch + EXPIRES_IN ))
expires_at_utc="$(date -u -r "$expires_epoch" +%Y-%m-%dT%H:%M:%SZ)"

# --- mutate manifest --------------------------------------------------------
new_manifest="$manifest.new.$$"
jq \
  --arg bucket   "$R2_BUCKET" \
  --arg key      "$object_key" \
  --arg endpoint "$R2_ENDPOINT" \
  --arg up_at    "$uploaded_at_utc" \
  --arg url      "$presigned_url" \
  --argjson exp_s "$EXPIRES_IN" \
  --arg exp_at   "$expires_at_utc" \
  '. + {
    uploaded: true,
    upload: {
      bucket:             $bucket,
      key:                $key,
      endpoint_url:       $endpoint,
      uploaded_at_utc:    $up_at,
      presigned_url:      $url,
      expires_in_seconds: $exp_s,
      expires_at_utc:     $exp_at
    }
  }' "$manifest" > "$new_manifest"

if ! jq -e . "$new_manifest" >/dev/null 2>&1; then
  err "failed to produce valid manifest"
  rm -f "$new_manifest"
  exit 3
fi

mv "$new_manifest" "$manifest"

log "uploaded    : s3://$R2_BUCKET/$object_key"
log "expires_at  : $expires_at_utc"
log "manifest    : updated (uploaded=true, upload.*)"
log "done"

# stdout: the presigned URL (so downstream callers can consume it)
printf '%s\n' "$presigned_url"
