#!/usr/bin/env bash
# share.sh — Phase 5 orchestrator of the chronicle-share pipeline.
#
# Chain the five per-phase scripts into a single invocation:
#   1. bundle.sh    Enumerate project's session JSONL into a staging dir.
#   2. sanitize.sh  Shell out to upstream sanitizer; redact secrets.
#   3. archive.sh   Pack sanitized staging into chronicle-share.tar.gz.
#   4. upload.sh    Push to Cloudflare R2 + emit 7-day presigned URL.
#   5. post.sh      Post presigned URL + summary to Telegram (unless --no-post).
#
# On success, stdout is the presigned URL (one line, pipe-friendly). The
# staging dir is removed on full success. On any phase failure, the staging
# dir is preserved (regardless of --keep-staging) for inspection.
#
# Usage:
#   share.sh [--project PATH] [--limit N]
#            [--expires-in SECONDS] [--key-prefix PATH]
#            [--no-post] [--post-chat-id ID] [--post-topic-id N]
#            [--dry-run-upload] [--keep-staging]
#   share.sh --help
#
# Exit codes:
#   0  full pipeline success
#   1  usage / validation error
#   2  bundle.sh failed
#   3  sanitize.sh failed
#   4  archive.sh failed
#   5  upload.sh failed
#   6  post.sh failed

set -uo pipefail

# --- locate sibling scripts (resolve symlinks) ------------------------------
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
done
HERE="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

BUNDLE="$HERE/bundle.sh"
SANITIZE="$HERE/sanitize.sh"
ARCHIVE="$HERE/archive.sh"
UPLOAD="$HERE/upload.sh"
POST="$HERE/post.sh"

# --- defaults ---------------------------------------------------------------
PROJECT=""
LIMIT=""
EXPIRES_IN=""
KEY_PREFIX=""
DRY_RUN_UPLOAD=0
KEEP_STAGING=0
NO_POST=0
POST_CHAT_ID=""
POST_TOPIC_ID=""

log() { printf '[share] %s\n' "$*" >&2; }
err() { printf '[share] ERROR: %s\n' "$*" >&2; }
hdr() { printf '\n[share] ===== %s =====\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: share.sh [OPTIONS]

Run the full chronicle-share pipeline (bundle → sanitize → archive → upload
→ post) and emit the 7-day presigned URL on stdout.

Options (forwarded to bundle.sh):
  --project PATH        Project whose sessions to share (default: $PWD).
  --limit N             Bundle only N newest sessions by mtime (0 = all).

Options (forwarded to upload.sh):
  --expires-in SECONDS  Presigned URL TTL (default: 604800 = 7 days, max 604800).
  --key-prefix PATH     Override default R2 object key prefix (default: chronicles).
  --dry-run-upload      Run bundle/sanitize/archive for real but DRY-RUN the
                        upload (validates creds, prints plan, no R2 write).
                        Implies --no-post (no URL to post).

Options (forwarded to post.sh):
  --post-chat-id ID     Telegram chat ID (default: -1003958083153, Bruntwork).
                        For testing: 7730224133 = saved messages.
  --post-topic-id N     Forum topic ID (default: 2, Assignments & Deliverables).
  --no-post             Skip Phase 6; emit presigned URL to stdout only.

Options (share.sh only):
  --keep-staging        Preserve the staging dir after successful upload
                        (always preserved on failure, regardless of this flag).
  --help, -h            Show this help.

Stdout (on success): a single line — the 7-day presigned URL.
Stderr: progress logs from every phase.
EOF
}

# --- arg parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)          PROJECT="${2:?--project requires a path}";         shift 2 ;;
    --limit)            LIMIT="${2:?--limit requires a number}";           shift 2 ;;
    --expires-in)       EXPIRES_IN="${2:?--expires-in requires SECONDS}";  shift 2 ;;
    --key-prefix)       KEY_PREFIX="${2:?--key-prefix requires a path}";   shift 2 ;;
    --post-chat-id)     POST_CHAT_ID="${2:?--post-chat-id requires ID}";   shift 2 ;;
    --post-topic-id)    POST_TOPIC_ID="${2:?--post-topic-id requires N}";  shift 2 ;;
    --no-post)          NO_POST=1; shift ;;
    --dry-run-upload)   DRY_RUN_UPLOAD=1; shift ;;
    --keep-staging)     KEEP_STAGING=1; shift ;;
    --help|-h)          usage; exit 0 ;;
    *)                  err "unknown arg: $1"; usage >&2; exit 1 ;;
  esac
done

# --dry-run-upload implies --no-post (dry-run has no real URL to share)
if [[ "$DRY_RUN_UPLOAD" -eq 1 ]]; then
  NO_POST=1
fi

# --- validate sibling scripts exist -----------------------------------------
required_siblings=("$BUNDLE" "$SANITIZE" "$ARCHIVE" "$UPLOAD")
if [[ "$NO_POST" -eq 0 ]]; then
  required_siblings+=("$POST")
fi
for s in "${required_siblings[@]}"; do
  if [[ ! -x "$s" ]]; then
    err "sibling script missing or not executable: $s"
    exit 1
  fi
done

# --- assemble forwarded args -----------------------------------------------
bundle_args=()
[[ -n "$PROJECT" ]] && bundle_args+=(--project "$PROJECT")
[[ -n "$LIMIT"   ]] && bundle_args+=(--limit   "$LIMIT")

upload_args=()
[[ -n "$EXPIRES_IN" ]] && upload_args+=(--expires-in "$EXPIRES_IN")
[[ -n "$KEY_PREFIX" ]] && upload_args+=(--key-prefix "$KEY_PREFIX")
[[ "$DRY_RUN_UPLOAD" -eq 1 ]] && upload_args+=(--dry-run)

post_args=()
[[ -n "$POST_CHAT_ID"  ]] && post_args+=(--chat-id  "$POST_CHAT_ID")
[[ -n "$POST_TOPIC_ID" ]] && post_args+=(--topic-id "$POST_TOPIC_ID")

# --- pipeline ---------------------------------------------------------------
STAGING=""

cleanup_on_success() {
  if [[ -n "$STAGING" && "$KEEP_STAGING" -eq 0 && "$DRY_RUN_UPLOAD" -eq 0 ]]; then
    rm -rf "$STAGING"
    log "staging removed: $STAGING"
  elif [[ -n "$STAGING" ]]; then
    log "staging preserved: $STAGING"
  fi
}

preserve_on_fail() {
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then
    log "staging preserved for debug: $STAGING"
  fi
}

# 1. BUNDLE ----------------------------------------------------------------
hdr "Phase 1: bundle"
bundle_stdout_file="$(mktemp)"
trap 'rm -f "$bundle_stdout_file"' EXIT

if ! "$BUNDLE" ${bundle_args[@]+"${bundle_args[@]}"} > "$bundle_stdout_file"; then
  err "bundle.sh failed"
  exit 2
fi

STAGING="$(tail -n 1 "$bundle_stdout_file")"
rm -f "$bundle_stdout_file"

if [[ -z "$STAGING" || ! -d "$STAGING" ]]; then
  err "bundle.sh did not produce a valid STAGING dir (got: '$STAGING')"
  exit 2
fi

log "staging = $STAGING"

# 2. SANITIZE --------------------------------------------------------------
hdr "Phase 2: sanitize"
if ! "$SANITIZE" "$STAGING" >/dev/null; then
  err "sanitize.sh failed"
  preserve_on_fail
  exit 3
fi

# 3. ARCHIVE ---------------------------------------------------------------
hdr "Phase 3: archive"
if ! "$ARCHIVE" "$STAGING" >/dev/null; then
  err "archive.sh failed"
  preserve_on_fail
  exit 4
fi

# 4. UPLOAD ----------------------------------------------------------------
hdr "Phase 4: upload"
upload_stdout_file="$(mktemp)"
trap 'rm -f "$upload_stdout_file"' EXIT

if ! "$UPLOAD" ${upload_args[@]+"${upload_args[@]}"} "$STAGING" > "$upload_stdout_file"; then
  err "upload.sh failed"
  rm -f "$upload_stdout_file"
  preserve_on_fail
  exit 5
fi

# On a real upload, stdout is the presigned URL. On --dry-run, stdout is empty.
presigned_url="$(tail -n 1 "$upload_stdout_file")"
rm -f "$upload_stdout_file"

# 5. POST ------------------------------------------------------------------
if [[ "$NO_POST" -eq 0 ]]; then
  hdr "Phase 6: post"
  post_stdout_file="$(mktemp)"
  trap 'rm -f "$post_stdout_file"' EXIT

  if ! "$POST" ${post_args[@]+"${post_args[@]}"} "$STAGING" > "$post_stdout_file"; then
    err "post.sh failed"
    rm -f "$post_stdout_file"
    preserve_on_fail
    exit 6
  fi

  post_message_id="$(tail -n 1 "$post_stdout_file")"
  rm -f "$post_stdout_file"
  log "posted  : message_id=$post_message_id"
fi

# --- summary + cleanup ------------------------------------------------------
hdr "done"
if [[ "$DRY_RUN_UPLOAD" -eq 1 ]]; then
  log "DRY-RUN — no URL emitted; no cleanup (manifest unchanged)"
  log "staging preserved: $STAGING"
else
  log "pipeline complete"
  cleanup_on_success
  # Real presigned URL → stdout for caller to consume.
  if [[ -n "$presigned_url" ]]; then
    printf '%s\n' "$presigned_url"
  else
    err "upload.sh succeeded but did not print a presigned URL"
    exit 5
  fi
fi
