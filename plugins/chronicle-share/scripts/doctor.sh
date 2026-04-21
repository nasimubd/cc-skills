#!/usr/bin/env bash
# doctor.sh — Phase 7 preflight diagnostic for the chronicle-share pipeline.
#
# Runs a panel of checks covering:
#   - external tools on PATH (jq, shasum, tar, aws, op, uv, curl)
#   - 1Password sign-in + item "R2 Chronicle Share" accessibility
#   - Telethon session file present
#   - Claude Code session directory discoverable
#   - R2 bucket reachability (HEAD via aws)
#   - Upstream sanitizer locatable (~/.claude/plugins/marketplaces/... or ~/eon/...)
#   - Sibling pipeline scripts all present + executable
#
# Report format per-check:
#   [PASS] <name> — <detail>
#   [WARN] <name> — <detail>   (non-fatal, e.g. optional tool missing)
#   [FAIL] <name> — <detail>   (fatal, pipeline won't work)
#
# Exit codes:
#   0  all checks pass
#   1  warnings only (pipeline works but something is sub-optimal)
#   2  one or more failures (pipeline will not work)
#
# Usage:
#   doctor.sh [--quiet] [--json]
#   doctor.sh --help

set -uo pipefail

QUIET=0
JSON=0

# --- locate self -----------------------------------------------------------
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"; done
HERE="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# --- accumulators ----------------------------------------------------------
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT

pass() { PASS_COUNT=$((PASS_COUNT+1)); printf '%s\t%s\t%s\n' "PASS" "$1" "$2" >> "$RESULTS_FILE"; }
warn() { WARN_COUNT=$((WARN_COUNT+1)); printf '%s\t%s\t%s\n' "WARN" "$1" "$2" >> "$RESULTS_FILE"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf '%s\t%s\t%s\n' "FAIL" "$1" "$2" >> "$RESULTS_FILE"; }

usage() {
  cat <<'EOF'
Usage: doctor.sh [OPTIONS]

Run preflight diagnostics for the chronicle-share pipeline.

Options:
  --quiet   Suppress per-check output; only print the summary + exit code.
  --json    Emit the full report as a JSON array (overrides --quiet).
  --help    Show this help.

Exit codes: 0 = all pass, 1 = warnings only, 2 = at least one FAIL.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --json)  JSON=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Check: required tools on PATH
# ---------------------------------------------------------------------------
for t in jq shasum tar awk find date; do
  if command -v "$t" >/dev/null 2>&1; then
    pass "tool:$t" "found at $(command -v "$t")"
  else
    fail "tool:$t" "not on PATH — install via brew"
  fi
done

# uv — fatal for Phase 2 sanitizer + Phase 6 post
if command -v uv >/dev/null 2>&1; then
  ver="$(uv --version 2>/dev/null | awk '{print $2}')"
  pass "tool:uv" "v$ver"
else
  fail "tool:uv" "missing — install: brew install uv"
fi

# aws — fatal for Phase 4
if command -v aws >/dev/null 2>&1; then
  ver="$(aws --version 2>&1 | awk '{print $1}')"
  pass "tool:aws" "$ver"
else
  fail "tool:aws" "missing — install: brew install awscli"
fi

# op — fatal for Phase 4 credentials
if command -v op >/dev/null 2>&1; then
  ver="$(op --version 2>/dev/null)"
  pass "tool:op" "v$ver"
else
  fail "tool:op" "missing — install: brew install 1password-cli"
fi

# curl — optional, used only for doctor's R2 HEAD check
if command -v curl >/dev/null 2>&1; then
  pass "tool:curl" "found"
else
  warn "tool:curl" "missing — R2 HEAD check will be skipped"
fi

# ---------------------------------------------------------------------------
# Check: 1Password sign-in + R2 item accessibility
# ---------------------------------------------------------------------------
OP_ACCOUNT="E37RVJRKWZAVFEXY6X2VA4PBWA"
OP_ITEM="op://Personal/R2 Chronicle Share"

if command -v op >/dev/null 2>&1; then
  if op account list 2>/dev/null | grep -q "$OP_ACCOUNT"; then
    pass "op:account" "$OP_ACCOUNT registered"

    # Try reading all four fields
    op_failed=0
    for field in username credential endpoint_url bucket_name; do
      if ! op read "$OP_ITEM/$field" --account="$OP_ACCOUNT" >/dev/null 2>&1; then
        op_failed=1
        fail "op:item:$field" "cannot read $OP_ITEM/$field — sign in: op signin --account=$OP_ACCOUNT"
      fi
    done
    if [[ "$op_failed" -eq 0 ]]; then
      pass "op:item" "all 4 fields readable ($OP_ITEM)"
    fi
  else
    fail "op:account" "account $OP_ACCOUNT not registered — op account add ..."
  fi
fi

# ---------------------------------------------------------------------------
# Check: Telethon session file
# ---------------------------------------------------------------------------
TG_SESSION="$HOME/.local/share/telethon/nasim.session"
if [[ -f "$TG_SESSION" ]]; then
  size=$(stat -f %z "$TG_SESSION")
  pass "telethon:session" "present ($size bytes) at $TG_SESSION"
else
  fail "telethon:session" "missing — authenticate Telethon first"
fi

# ---------------------------------------------------------------------------
# Check: Claude Code session directory for the current project
# ---------------------------------------------------------------------------
proj="${PWD}"
enc="-$(printf '%s' "$proj" | sed 's|^/||' | tr '/.' '--')"
session_dir="$HOME/.claude/projects/$enc"
if [[ -d "$session_dir" ]]; then
  count=$(find "$session_dir" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | wc -l | awk '{print $1}')
  if [[ "$count" -gt 0 ]]; then
    pass "sessions:current" "$count session(s) in $session_dir"
  else
    warn "sessions:current" "directory exists but no *.jsonl — no sessions to bundle yet"
  fi
else
  warn "sessions:current" "no session dir for \$PWD ($proj); run from a project with Claude Code history"
fi

# ---------------------------------------------------------------------------
# Check: upstream sanitizer locatable
# ---------------------------------------------------------------------------
SAN_CANDIDATES=(
  "$HOME/.claude/plugins/marketplaces/cc-skills/plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py"
  "$HOME/eon/cc-skills/plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py"
)
sanitizer_found=""
for c in "${SAN_CANDIDATES[@]}"; do
  if [[ -f "$c" ]]; then sanitizer_found="$c"; break; fi
done
if [[ -n "$sanitizer_found" ]]; then
  pass "sanitizer:upstream" "found at $sanitizer_found"
else
  fail "sanitizer:upstream" "devops-tools sanitize_sessions.py not found in either candidate path"
fi

# ---------------------------------------------------------------------------
# Check: sibling pipeline scripts
# ---------------------------------------------------------------------------
for s in bundle.sh sanitize.sh archive.sh upload.sh share.sh post.sh; do
  if [[ -x "$HERE/$s" ]]; then
    pass "script:$s" "present + executable"
  else
    fail "script:$s" "missing or not executable at $HERE/$s"
  fi
done

# ---------------------------------------------------------------------------
# Check: R2 bucket reachability (HEAD via aws) — only if op accessible
# ---------------------------------------------------------------------------
if command -v aws >/dev/null 2>&1 && command -v op >/dev/null 2>&1; then
  # Load creds; skip the check if any fail (reported separately above).
  ak="$(op read "$OP_ITEM/username"     --account="$OP_ACCOUNT" 2>/dev/null || true)"
  sk="$(op read "$OP_ITEM/credential"   --account="$OP_ACCOUNT" 2>/dev/null || true)"
  ep="$(op read "$OP_ITEM/endpoint_url" --account="$OP_ACCOUNT" 2>/dev/null || true)"
  bk="$(op read "$OP_ITEM/bucket_name"  --account="$OP_ACCOUNT" 2>/dev/null || true)"
  if [[ -n "$ak" && -n "$sk" && -n "$ep" && -n "$bk" ]]; then
    # aws s3api head-bucket is the cheapest reachability probe.
    if AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_DEFAULT_REGION=auto \
       aws s3api head-bucket --bucket "$bk" --endpoint-url "$ep" >/dev/null 2>&1; then
      pass "r2:bucket" "$bk reachable at $ep"
    else
      fail "r2:bucket" "head-bucket on $bk failed — token scope may be wrong or bucket deleted"
    fi
  else
    # Credential fetch already reported. Don't duplicate the failure.
    warn "r2:bucket" "skipped — credentials unavailable (see op: checks above)"
  fi
fi

# ---------------------------------------------------------------------------
# Render report
# ---------------------------------------------------------------------------
if [[ "$JSON" -eq 1 ]]; then
  # Emit JSON array
  awk -F'\t' 'BEGIN {printf "["} NR>1 {printf ","} {
    gsub(/"/, "\\\"", $3);
    printf "{\"status\":\"%s\",\"check\":\"%s\",\"detail\":\"%s\"}", $1, $2, $3
  } END {printf "]"}' "$RESULTS_FILE"
  echo
elif [[ "$QUIET" -eq 0 ]]; then
  while IFS=$'\t' read -r status check detail; do
    case "$status" in
      PASS) printf '[PASS] %-26s %s\n' "$check" "$detail" ;;
      WARN) printf '[WARN] %-26s %s\n' "$check" "$detail" ;;
      FAIL) printf '[FAIL] %-26s %s\n' "$check" "$detail" ;;
    esac
  done < "$RESULTS_FILE"
fi

total=$((PASS_COUNT+WARN_COUNT+FAIL_COUNT))
if [[ "$QUIET" -eq 0 && "$JSON" -eq 0 ]]; then
  printf '\n'
  printf '==========================================\n'
  printf '  %d pass · %d warn · %d fail (of %d)\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$total"
  printf '==========================================\n'
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then exit 2; fi
if [[ "$WARN_COUNT" -gt 0 ]]; then exit 1; fi
exit 0
