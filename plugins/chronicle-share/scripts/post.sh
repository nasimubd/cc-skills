#!/usr/bin/env bash
# post.sh — Phase 6 of the chronicle-share pipeline.
#
# Post the Phase 4 presigned URL + summary into a Telegram chat (default:
# Bruntwork supergroup -1003958083153, forum topic 2 "Assignments & Deliverables").
# Uses Nasim's personal Telethon profile at ~/.local/share/telethon/nasim.session.
#
# Input contract (produced by Phase 4, upload.sh):
#   $STAGING/manifest.json with uploaded=true and upload.presigned_url populated.
#
# Output:
#   A Telegram message in the target chat/topic.
#   $STAGING/manifest.json mutated: posted=true + post.* subfield.
#   Stdout: the message_id (integer, one line).
#
# Usage:
#   post.sh [--chat-id ID] [--topic-id N] [--dry-run] [--force] STAGING_DIR
#   post.sh --help
#
# Exit codes:
#   0  message sent + manifest mutated
#   1  usage / validation error
#   2  Telethon send failed
#   3  manifest mutation failed

set -uo pipefail

STAGING=""
CHAT_ID="-1003958083153"    # Bruntwork supergroup
TOPIC_ID="2"                # Assignments & Deliverables
DRY_RUN=0
FORCE=0

# Telegram MTProto API (Nasim's personal dev app)
TG_API_ID="32899228"
TG_API_HASH="d6a5eeffb0453c5d9ec49423b172c2fc"
TG_SESSION="$HOME/.local/share/telethon/nasim"

log() { printf '[post] %s\n' "$*" >&2; }
err() { printf '[post] ERROR: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: post.sh [OPTIONS] STAGING_DIR

Post the Phase 4 presigned URL + summary into a Telegram chat.

Options:
  --chat-id ID      Target chat ID (default: -1003958083153, Bruntwork).
                    For testing: 7730224133 = Nasim's saved messages.
  --topic-id N      Forum topic ID (default: 2, Assignments & Deliverables).
                    Ignored for non-forum chats (e.g. DMs).
  --dry-run         Preview the message body and send args, do NOT post.
  --force           Bypass the posted=true idempotency guard.
  --help, -h        Show this help.

Telethon profile: nasim (session at ~/.local/share/telethon/nasim.session).
Must already be signed in.

After success:
  - Message posted to (chat_id, topic_id)
  - manifest.json mutated: posted=true + post.*
  - Stdout: the message_id (integer)
EOF
}

# --- arg parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat-id)  CHAT_ID="${2:?--chat-id requires a value}";  shift 2 ;;
    --topic-id) TOPIC_ID="${2:?--topic-id requires a value}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    --help|-h)  usage; exit 0 ;;
    --*)        err "unknown arg: $1"; usage >&2; exit 1 ;;
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
for bin in jq uv; do
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

if [[ ! -f "$manifest" ]]; then
  err "manifest.json not found: $manifest"
  exit 1
fi

if ! jq -e . "$manifest" >/dev/null 2>&1; then
  err "manifest.json is not valid JSON"
  exit 1
fi

# --- guard: must be uploaded ------------------------------------------------
is_uploaded="$(jq -r '.uploaded // false' "$manifest")"
if [[ "$is_uploaded" != "true" ]]; then
  err "manifest.uploaded is not true — run upload.sh first"
  exit 1
fi

# --- guard: idempotency -----------------------------------------------------
is_posted="$(jq -r '.posted // false' "$manifest")"
if [[ "$is_posted" == "true" && "$FORCE" -ne 1 ]]; then
  err "manifest.posted is already true — refusing to re-post"
  err "  pass --force to override"
  exit 1
fi

# --- extract manifest fields ------------------------------------------------
project_path="$(jq -r '.source.project_path'     "$manifest")"
session_cnt="$( jq -r '.totals.session_count'    "$manifest")"
total_bytes="$( jq -r '.totals.total_size_bytes' "$manifest")"
redactions="$(  jq -r '.redactions.total // 0'   "$manifest")"
archive_sha="$( jq -r '.archive.sha256'          "$manifest")"
archive_size="$(jq -r '.archive.size_bytes'      "$manifest")"
presigned="$(   jq -r '.upload.presigned_url'    "$manifest")"
expires_at="$(  jq -r '.upload.expires_at_utc'   "$manifest")"

for v in project_path presigned expires_at archive_sha; do
  val="${!v}"
  if [[ -z "$val" || "$val" == "null" ]]; then
    err "manifest missing required field: $v"
    exit 1
  fi
done

short_sha="${archive_sha:0:12}"

# --- count sanitized lines (sum of line_count across sessions) --------------
total_lines="$(jq '[.sessions[].line_count] | add // 0' "$manifest")"

# --- pretty size helpers ----------------------------------------------------
fmt_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b < 1024)            printf "%d B", b
    else if (b < 1048576)    printf "%.1f KB", b/1024
    else if (b < 1073741824) printf "%.2f MB", b/1048576
    else                     printf "%.2f GB", b/1073741824
  }'
}
archive_size_pretty="$(fmt_bytes "$archive_size")"
total_size_pretty="$(fmt_bytes "$total_bytes")"

# --- build message body (Markdown) ------------------------------------------
# Telegram Markdown: *bold*, _italic_, `code`, [label](url)
msg_body=$(cat <<MSG
📦 *Session chronicle ready for review*

*Project:* \`${project_path}\`
*Sessions:* ${session_cnt} session(s), ${total_lines} line(s) (${total_size_pretty} raw)
*Redactions:* ${redactions}
*Archive:* ${archive_size_pretty} (gzip) · SHA-256 \`${short_sha}...\`

[Download (7-day presigned URL)](${presigned})

_Expires ${expires_at}. Generated by chronicle-share._
MSG
)

# --- dry-run short-circuit --------------------------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "chat_id  : $CHAT_ID"
  log "topic_id : $TOPIC_ID"
  log "DRY-RUN — would send this message:"
  printf '%s\n' "$msg_body" | sed 's/^/[post]   | /' >&2
  log "DRY-RUN — no changes made; manifest unchanged"
  exit 0
fi

# --- send via Telethon ------------------------------------------------------
log "sending to chat_id=$CHAT_ID topic_id=$TOPIC_ID..."

# Write message body to a tempfile so we don't need to escape it for the heredoc.
msg_file="$(mktemp)"
printf '%s' "$msg_body" > "$msg_file"
resp_file="$(mktemp)"
trap 'rm -f "$msg_file" "$resp_file"' EXIT

# Run Telethon via uv. The Python script reads the message from MSG_FILE and
# writes a JSON response {"ok":true,"message_id":N} to RESP_FILE.
#
# Note: Telethon forum topics are sent by passing reply_to=<topic_id>. For
# non-forum chats (including DMs), topic_id is ignored.
VIRTUAL_ENV="" MSG_FILE="$msg_file" RESP_FILE="$resp_file" \
  TG_API_ID="$TG_API_ID" TG_API_HASH="$TG_API_HASH" TG_SESSION="$TG_SESSION" \
  TG_CHAT_ID="$CHAT_ID" TG_TOPIC_ID="$TOPIC_ID" \
  uv run --python 3.13 --no-project --with telethon python3 <<'PYEOF' 2>&1 >/dev/null
import asyncio, json, os, sys
from telethon import TelegramClient
from telethon.errors import RPCError

async def main():
    with open(os.environ["MSG_FILE"], "r") as fp:
        body = fp.read()
    client = TelegramClient(
        os.environ["TG_SESSION"],
        int(os.environ["TG_API_ID"]),
        os.environ["TG_API_HASH"],
    )
    async with client:
        chat_id = int(os.environ["TG_CHAT_ID"])
        topic_id = int(os.environ["TG_TOPIC_ID"])
        kwargs = {"parse_mode": "md", "link_preview": False}
        # For supergroups with forum mode on, reply_to=<topic_id> routes to topic.
        # For DMs / non-forum groups, omitting reply_to sends to the main thread.
        if chat_id < 0 and topic_id >= 1:
            kwargs["reply_to"] = topic_id
        try:
            msg = await client.send_message(chat_id, body, **kwargs)
        except RPCError as e:
            with open(os.environ["RESP_FILE"], "w") as fp:
                json.dump({"ok": False, "error": f"{type(e).__name__}: {e}"}, fp)
            sys.exit(2)
        with open(os.environ["RESP_FILE"], "w") as fp:
            json.dump({"ok": True, "message_id": msg.id}, fp)

asyncio.run(main())
PYEOF
rc=$?

if [[ "$rc" -ne 0 ]]; then
  err "Telethon subprocess failed (exit $rc)"
  [[ -s "$resp_file" ]] && err "  details: $(cat "$resp_file")"
  exit 2
fi

if [[ ! -s "$resp_file" ]]; then
  err "Telethon subprocess produced no response"
  exit 2
fi

resp_ok="$(  jq -r '.ok'         "$resp_file" 2>/dev/null || echo "false")"
if [[ "$resp_ok" != "true" ]]; then
  err "Telethon send failed: $(jq -r '.error // "unknown"' "$resp_file")"
  exit 2
fi

message_id="$(jq -r '.message_id' "$resp_file")"
if [[ -z "$message_id" || "$message_id" == "null" ]]; then
  err "Telethon returned ok but no message_id"
  exit 2
fi

# --- mutate manifest --------------------------------------------------------
posted_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

new_manifest="$manifest.new.$$"
jq \
  --arg chat "$CHAT_ID" \
  --argjson topic "$TOPIC_ID" \
  --argjson mid "$message_id" \
  --arg pt "$posted_at_utc" \
  --arg body "$msg_body" \
  '. + {
    posted: true,
    post: {
      platform:      "telegram",
      chat_id:       $chat,
      topic_id:      $topic,
      message_id:    $mid,
      posted_at_utc: $pt,
      message_body:  $body
    }
  }' "$manifest" > "$new_manifest"

if ! jq -e . "$new_manifest" >/dev/null 2>&1; then
  err "failed to produce valid manifest"
  rm -f "$new_manifest"
  exit 3
fi

mv "$new_manifest" "$manifest"

log "sent       : message_id=$message_id"
log "chat/topic : $CHAT_ID / $TOPIC_ID"
log "manifest   : updated (posted=true, post.*)"
log "done"

printf '%s\n' "$message_id"
