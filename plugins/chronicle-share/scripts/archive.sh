#!/usr/bin/env bash
# archive.sh — Phase 3 of the chronicle-share pipeline.
#
# Pack the sanitized staging dir into a single `chronicle-share.tar.gz` artifact
# and mutate manifest.json in place to record what happened.
#
# Input contract (produced by Phase 2, sanitize.sh):
#   $STAGING/manifest.json           sanitized=true, archived=false
#   $STAGING/sessions-sanitized/     redacted JSONL payload
#   $STAGING/redaction_report.txt    human-readable redaction summary
#
# Output:
#   $STAGING/chronicle-share.tar.gz         the upload artifact (Phase 4 input)
#   $STAGING/chronicle-share.tar.gz.sha256  sidecar for verification
#   $STAGING/manifest.json                  archived=true + new archive metadata
#
# Raw $STAGING/sessions/ is NOT included in the archive (it still contains
# pre-sanitization data).
#
# Usage:
#   archive.sh [--force] STAGING_DIR
#   archive.sh --help
#
# Stdout: the same STAGING_DIR (so the pipeline can be chained).
# Stderr: all human-readable logs.
#
# Exit codes:
#   0  archive created
#   1  usage / validation error (missing staging, not sanitized, already archived, etc.)
#   2  archive creation failed (tar / sha256 computation / manifest mutation)

set -euo pipefail

STAGING=""
FORCE=0

# --- constants --------------------------------------------------------------
ARCHIVE_NAME="chronicle-share.tar.gz"
ARCHIVE_FORMAT="tar.gz"

log() { printf '[archive] %s\n' "$*" >&2; }
err() { printf '[archive] ERROR: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: archive.sh [OPTIONS] STAGING_DIR

Pack the sanitized staging dir into a single chronicle-share.tar.gz artifact.
STAGING_DIR must be the path previously returned by sanitize.sh on stdout
(i.e. its manifest.json has sanitized=true).

Options:
  --force      Re-archive even if manifest.archived is already true.
  --help, -h   Show this help.

After success, STAGING_DIR contains:
  manifest.json                        (mutated: archived=true, archive.*)
  chronicle-share.tar.gz               (the upload artifact for Phase 4)
  chronicle-share.tar.gz.sha256        (sidecar for easy verification)
  sessions/                            (unchanged — not included in archive)
  sessions-sanitized/                  (unchanged on disk, packaged in archive)
  redaction_report.txt                 (unchanged on disk, packaged in archive)

Archive contents (extracted by consumers):
  manifest.json                        (point-in-time snapshot)
  sessions-sanitized/*.jsonl           (the redacted JSONL payload)
  redaction_report.txt                 (human-readable redaction summary)

Idempotency: refuses to run if manifest.archived is already true. Pass --force
to re-create the archive (e.g. after fixing a downstream bug and re-running).
EOF
}

# --- arg parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)     FORCE=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    --*)         err "unknown arg: $1"; usage >&2; exit 1 ;;
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

# --- validate deps ----------------------------------------------------------
for bin in jq shasum stat tar awk; do
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

STAGING="$(cd "$STAGING" && pwd)"   # normalize to absolute
manifest="$STAGING/manifest.json"
sanitized_dir="$STAGING/sessions-sanitized"
report="$STAGING/redaction_report.txt"

if [[ ! -f "$manifest" ]]; then
  err "manifest.json not found: $manifest"
  exit 1
fi

if ! jq -e . "$manifest" >/dev/null 2>&1; then
  err "manifest.json is not valid JSON: $manifest"
  exit 1
fi

if [[ ! -d "$sanitized_dir" ]]; then
  err "sessions-sanitized/ not found — run sanitize.sh first: $sanitized_dir"
  exit 1
fi

if [[ ! -f "$report" ]]; then
  err "redaction_report.txt not found — run sanitize.sh first: $report"
  exit 1
fi

# --- guard: must be sanitized -----------------------------------------------
is_sanitized="$(jq -r '.sanitized // false' "$manifest")"
if [[ "$is_sanitized" != "true" ]]; then
  err "manifest.sanitized is not true — run sanitize.sh first"
  exit 1
fi

# --- guard: idempotency -----------------------------------------------------
is_archived="$(jq -r '.archived // false' "$manifest")"
if [[ "$is_archived" == "true" && "$FORCE" -ne 1 ]]; then
  err "manifest.archived is already true — refusing to re-archive"
  err "  pass --force to override"
  exit 1
fi

# --- validate sanitized contents --------------------------------------------
sanitized_count=$(find "$sanitized_dir" -maxdepth 1 -type f -name '*.jsonl' | wc -l | awk '{print $1}')
if [[ "$sanitized_count" -eq 0 ]]; then
  err "sessions-sanitized/ has no *.jsonl files — nothing to archive"
  exit 1
fi

expected_count="$(jq -r '.totals.session_count' "$manifest")"
if [[ "$expected_count" != "$sanitized_count" ]]; then
  err "manifest.totals.session_count=$expected_count but sessions-sanitized/ has $sanitized_count files"
  exit 1
fi

# --- compute archive metadata (pre-tar) -------------------------------------
archive_path="$STAGING/$ARCHIVE_NAME"
sha_sidecar="$archive_path.sha256"
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Contents list — symbolic, not per-file, so the list stays stable across runs.
contents_json='["manifest.json","sessions-sanitized/*.jsonl","redaction_report.txt"]'

log "staging  : $STAGING"
log "archive  : $archive_path"
log "payload  : $sanitized_count sanitized session(s) + report + manifest"

# --- write pre-archive manifest snapshot (for embedding) --------------------
# The manifest that goes INTO the archive has archived=true and the archive
# subfield populated EXCEPT for size_bytes/sha256 (self-referential — can't
# include a hash of a file that contains itself). The OUTER manifest (left in
# STAGING after archiving) gets those two extra fields added.
snapshot_manifest="$(mktemp)"
trap 'rm -f "$snapshot_manifest"' EXIT

jq \
  --arg fn       "$ARCHIVE_NAME" \
  --arg fmt      "$ARCHIVE_FORMAT" \
  --arg ca       "$now_utc" \
  --argjson cts  "$contents_json" \
  '. + {
    archived: true,
    archive: {
      filename:       $fn,
      format:         $fmt,
      created_at_utc: $ca,
      contents:       $cts
    }
  }' "$manifest" > "$snapshot_manifest"

if ! jq -e . "$snapshot_manifest" >/dev/null 2>&1; then
  err "failed to produce valid snapshot manifest"
  exit 2
fi

# Swap in the snapshot manifest BEFORE archiving so the embedded copy is
# up to date. The outer manifest will be upgraded (size+sha) after tar.
cp "$snapshot_manifest" "$manifest"

# --- create archive ---------------------------------------------------------
# Using BSD tar (macOS default). Relative paths preserve the original layout
# when the consumer extracts: manifest.json, sessions-sanitized/, redaction_report.txt.
#
# Remove stale artifact first (idempotency via --force).
rm -f "$archive_path" "$sha_sidecar"

(
  cd "$STAGING"
  tar -czf "$ARCHIVE_NAME" \
    manifest.json \
    sessions-sanitized \
    redaction_report.txt
) || {
  err "tar failed"
  exit 2
}

if [[ ! -f "$archive_path" ]]; then
  err "tar succeeded but archive file not found: $archive_path"
  exit 2
fi

# --- compute archive size + sha256 ------------------------------------------
archive_size="$(stat -f %z "$archive_path")"
archive_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"

# Write sidecar SHA file — "<sha>  <filename>\n" (same format as `shasum -a 256`)
printf '%s  %s\n' "$archive_sha" "$ARCHIVE_NAME" > "$sha_sidecar"

# --- mutate outer manifest to add size + sha --------------------------------
new_manifest="$manifest.new.$$"
jq \
  --argjson sz "$archive_size" \
  --arg     sh "$archive_sha" \
  '.archive += {size_bytes: $sz, sha256: $sh}' \
  "$manifest" > "$new_manifest"

if ! jq -e . "$new_manifest" >/dev/null 2>&1; then
  err "failed to produce valid outer manifest"
  rm -f "$new_manifest"
  exit 2
fi

mv "$new_manifest" "$manifest"

log "size     : $archive_size bytes"
log "sha256   : $archive_sha"
log "manifest : updated (archived=true, archive.size_bytes, archive.sha256)"
log "done"

printf '%s\n' "$STAGING"
