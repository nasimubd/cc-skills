#!/usr/bin/env bash
# test-post.sh — self-contained test suite for chronicle-share Phase 6.
#
# Mocks `uv` via a PATH shim so tests don't actually contact Telegram.
# The shim writes a fake JSON response to $RESP_FILE (as post.sh expects
# the real Telethon invocation to do).
#
# Shim failure modes via env vars:
#   MOCK_UV_FAIL=1       → uv subprocess exits non-zero
#   MOCK_TELETHON_FAIL=1 → response JSON has ok=false
#   MOCK_NO_RESPONSE=1   → response file stays empty

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/post.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FATAL: post.sh not found: $SCRIPT" >&2; exit 2
fi

PASS=0; FAIL=0
FAILED_NAMES=()
pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }
hdr()  { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------------------
# Shim uv — writes a fake JSON response to $RESP_FILE.
# ---------------------------------------------------------------------------
SHIM_DIR="$(mktemp -d -t chronicle-post-shims)"

cat > "$SHIM_DIR/uv" <<'SHIM_EOF'
#!/usr/bin/env bash
# Mock uv — consumes stdin (the Python script) and writes a fake telethon
# response to $RESP_FILE. Ignores the actual Python.
cat > /dev/null   # drain the heredoc so parent's redirection isn't closed early

if [[ "${MOCK_UV_FAIL:-0}" == "1" ]]; then
  echo "mock uv: forced failure" >&2
  exit 1
fi

if [[ "${MOCK_NO_RESPONSE:-0}" == "1" ]]; then
  # intentionally don't write $RESP_FILE
  exit 0
fi

if [[ "${MOCK_TELETHON_FAIL:-0}" == "1" ]]; then
  printf '{"ok": false, "error": "mock telethon failure"}' > "$RESP_FILE"
  exit 0
fi

# Happy path — emit a deterministic fake message_id.
printf '{"ok": true, "message_id": 424242}' > "$RESP_FILE"
SHIM_EOF
chmod +x "$SHIM_DIR/uv"

cleanup() { rm -rf "$SHIM_DIR"; }
trap cleanup EXIT

# IMPORTANT: prepend shim dir so our fake `uv` wins over the real one.
export PATH="$SHIM_DIR:$PATH"

# ---------------------------------------------------------------------------
# Stage builder — produces a full post-upload staging dir (post.sh's input).
# ---------------------------------------------------------------------------
mk_staged_uploaded() {
  local dir="$1"
  mkdir -p "$dir"
  jq -n \
    --arg gen_at "2026-04-21T00:00:00Z" \
    --arg proj "/tmp/fake-proj" \
    --arg enc  "-tmp-fake-proj" \
    '{
      manifest_version: 1,
      generated_at_utc: $gen_at,
      generated_by: "chronicle-share/bundle.sh",
      source: {project_path: $proj, project_encoded: $enc, host: "h", claude_user: "u"},
      sessions: [
        {session_id:"s1", filename:"s1.jsonl", size_bytes:100, line_count:50,
         mtime_utc:"2026-04-21T00:00:00Z", sha256:"aaa",
         sanitized_size_bytes:80, sanitized_line_count:50, sanitized_sha256:"bbb"}
      ],
      totals: {session_count: 1, total_size_bytes: 100},
      sanitized: true,
      archived: true,
      sanitization: {sanitized_at_utc:"2026-04-21T00:00:00Z",
                     sanitizer_path:"/fake", sanitizer_sha256:"sss",
                     report_path:"fake"},
      redactions: {total: 7, by_pattern: {email_address: 7}},
      archive: {
        filename: "chronicle-share.tar.gz",
        format: "tar.gz",
        created_at_utc: "2026-04-21T00:01:00Z",
        contents: ["manifest.json", "sessions-sanitized/*.jsonl", "redaction_report.txt"],
        size_bytes: 12345,
        sha256: "deadbeefcafe1234567890abcdef1234567890abcdef1234567890abcdef1234"
      },
      uploaded: true,
      upload: {
        bucket: "fake-bucket",
        key: "chronicles/-tmp-fake-proj/2026-04-21T00-01-00Z-deadbeef.tar.gz",
        endpoint_url: "https://fake.r2",
        uploaded_at_utc: "2026-04-21T00:02:00Z",
        presigned_url: "https://fake.r2/path?X-Amz-Signature=xxx",
        expires_in_seconds: 604800,
        expires_at_utc: "2026-04-28T00:02:00Z"
      }
    }' > "$dir/manifest.json"
}

mk_tmp() { mktemp -d -t chronicle-post-test; }

# ============================================================================
# Tests
# ============================================================================

hdr "Usage + arg parsing"

# 1. --help exits 0 with usage
out=$("$SCRIPT" --help 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$out" == *"Usage: post.sh"* ]]; then pass "01 --help"; else fail "01" "rc=$rc"; fi

# 2. Missing STAGING_DIR → exit 1
"$SCRIPT" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "02 missing STAGING exits 1"; else fail "02" "rc=$rc"; fi

# 3. Unknown flag → exit 1
"$SCRIPT" --bogus /tmp >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "03 unknown flag exits 1"; else fail "03" "rc=$rc"; fi

# 4. Two positional → exit 1
"$SCRIPT" /tmp/a /tmp/b >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "04 two positional exits 1"; else fail "04" "rc=$rc"; fi

hdr "Validation guards"

# 5. Nonexistent staging
"$SCRIPT" /tmp/no-such-$RANDOM >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "05 nonexistent staging exits 1"; else fail "05" "rc=$rc"; fi

# 6. Missing manifest
d=$(mk_tmp)
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "06 missing manifest exits 1"; else fail "06" "rc=$rc"; fi
rm -rf "$d"

# 7. Invalid JSON manifest
d=$(mk_tmp); echo "bad json {" > "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "07 invalid JSON exits 1"; else fail "07" "rc=$rc"; fi
rm -rf "$d"

# 8. uploaded=false refused
d=$(mk_tmp); mk_staged_uploaded "$d"
jq '.uploaded=false' "$d/manifest.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "08 uploaded=false refused (exit 1)"; else fail "08" "rc=$rc"; fi
rm -rf "$d"

# 9. Missing presigned_url (corrupted manifest)
d=$(mk_tmp); mk_staged_uploaded "$d"
jq 'del(.upload.presigned_url)' "$d/manifest.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "09 missing presigned_url exits 1"; else fail "09" "rc=$rc"; fi
rm -rf "$d"

hdr "Happy path (shimmed uv)"

d=$(mk_tmp); mk_staged_uploaded "$d"
out=$("$SCRIPT" "$d" 2>/dev/null); rc=$?

# 10. Exit 0
if [[ "$rc" -eq 0 ]]; then pass "10 happy path exits 0"; else fail "10" "rc=$rc"; fi

# 11. Stdout = message_id from shim
if [[ "$out" == "424242" ]]; then pass "11 stdout = shim message_id"; else fail "11" "got: $out"; fi

# 12. manifest.posted=true
posted=$(jq -r '.posted' "$d/manifest.json")
if [[ "$posted" == "true" ]]; then pass "12 manifest.posted=true"; else fail "12" "got: $posted"; fi

# 13. post subfield has all 6 keys
keys=$(jq -r '.post | keys | sort | join(",")' "$d/manifest.json")
expected="chat_id,message_body,message_id,platform,posted_at_utc,topic_id"
if [[ "$keys" == "$expected" ]]; then pass "13 post has all 6 keys"; else fail "13" "got: $keys"; fi

# 14. post.platform = telegram
plat=$(jq -r '.post.platform' "$d/manifest.json")
if [[ "$plat" == "telegram" ]]; then pass "14 post.platform=telegram"; else fail "14" "got: $plat"; fi

# 15. post.chat_id = default Bruntwork
chat=$(jq -r '.post.chat_id' "$d/manifest.json")
if [[ "$chat" == "-1003958083153" ]]; then pass "15 post.chat_id default = Bruntwork"; else fail "15" "got: $chat"; fi

# 16. post.topic_id = default 2
topic=$(jq -r '.post.topic_id' "$d/manifest.json")
if [[ "$topic" == "2" ]]; then pass "16 post.topic_id default = 2"; else fail "16" "got: $topic"; fi

# 17. post.message_id = 424242 from shim
mid=$(jq -r '.post.message_id' "$d/manifest.json")
if [[ "$mid" == "424242" ]]; then pass "17 post.message_id=424242"; else fail "17" "got: $mid"; fi

# 18. post.message_body contains project path
body=$(jq -r '.post.message_body' "$d/manifest.json")
if [[ "$body" == *"/tmp/fake-proj"* ]]; then pass "18 message_body contains project path"; else fail "18" "missing"; fi

# 19. post.message_body contains presigned URL
if [[ "$body" == *"https://fake.r2/path"* ]]; then pass "19 message_body contains presigned URL"; else fail "19" "missing"; fi

# 20. post.message_body contains short SHA
if [[ "$body" == *"deadbeefcafe"* ]]; then pass "20 message_body contains short SHA"; else fail "20" "missing"; fi
rm -rf "$d"

hdr "Idempotency + --force"

# 21. Re-post without --force → exit 1
d=$(mk_tmp); mk_staged_uploaded "$d"
"$SCRIPT" "$d" >/dev/null 2>&1   # first post — marks posted=true
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "21 re-post without --force refused"; else fail "21" "rc=$rc"; fi

# 22. --force succeeds after posted=true
old_posted_at=$(jq -r '.post.posted_at_utc' "$d/manifest.json")
sleep 1
"$SCRIPT" --force "$d" >/dev/null 2>&1; rc=$?
new_posted_at=$(jq -r '.post.posted_at_utc' "$d/manifest.json")
if [[ "$rc" -eq 0 && "$new_posted_at" != "$old_posted_at" ]]; then
  pass "22 --force re-post updates timestamp"
else
  fail "22 --force" "rc=$rc, same_ts=$([[ "$old_posted_at" == "$new_posted_at" ]] && echo yes || echo no)"
fi
rm -rf "$d"

hdr "Custom --chat-id + --topic-id"

# 23. --chat-id honored
d=$(mk_tmp); mk_staged_uploaded "$d"
"$SCRIPT" --chat-id 7730224133 --topic-id 1 "$d" >/dev/null 2>&1
chat=$(jq -r '.post.chat_id' "$d/manifest.json")
if [[ "$chat" == "7730224133" ]]; then pass "23 --chat-id honored"; else fail "23" "got: $chat"; fi

# 24. --topic-id honored
topic=$(jq -r '.post.topic_id' "$d/manifest.json")
if [[ "$topic" == "1" ]]; then pass "24 --topic-id honored"; else fail "24" "got: $topic"; fi
rm -rf "$d"

hdr "--dry-run"

# 25. --dry-run exits 0, no mutation
d=$(mk_tmp); mk_staged_uploaded "$d"
"$SCRIPT" --dry-run "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]]; then pass "25 --dry-run exits 0"; else fail "25" "rc=$rc"; fi

posted=$(jq -r '.posted // false' "$d/manifest.json")
has_post=$(jq -r 'has("post")' "$d/manifest.json")
if [[ "$posted" == "false" && "$has_post" == "false" ]]; then
  pass "26 --dry-run leaves manifest untouched"
else
  fail "26 dry-run mutated manifest" "posted=$posted, has_post=$has_post"
fi

# 27. --dry-run prints the would-be message to stderr
out=$("$SCRIPT" --dry-run "$d" 2>&1)
if [[ "$out" == *"Session chronicle"* && "$out" == *"fake-proj"* ]]; then
  pass "27 --dry-run prints message preview"
else
  fail "27 dry-run preview" "no expected markers"
fi
rm -rf "$d"

hdr "Telethon failure modes"

# 28. uv subprocess fails → exit 2
d=$(mk_tmp); mk_staged_uploaded "$d"
MOCK_UV_FAIL=1 "$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "28 uv failure → exit 2"; else fail "28" "rc=$rc"; fi
# Verify manifest unchanged
posted=$(jq -r '.posted // false' "$d/manifest.json")
if [[ "$posted" == "false" ]]; then
  pass "29 manifest unchanged when uv fails"
else
  fail "29 manifest should be unchanged" "posted=$posted"
fi
rm -rf "$d"

# 30. Telethon returns ok=false → exit 2
d=$(mk_tmp); mk_staged_uploaded "$d"
MOCK_TELETHON_FAIL=1 "$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "30 telethon ok=false → exit 2"; else fail "30" "rc=$rc"; fi
rm -rf "$d"

# 31. uv produces no response file → exit 2
d=$(mk_tmp); mk_staged_uploaded "$d"
MOCK_NO_RESPONSE=1 "$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "31 no response → exit 2"; else fail "31" "rc=$rc"; fi
rm -rf "$d"

# ============================================================================
# Summary
# ============================================================================
total=$((PASS+FAIL))
printf '\n'
printf '================================================================\n'
printf '  Phase 6 post.sh — %d/%d passed\n' "$PASS" "$total"
printf '================================================================\n'
if [[ "$FAIL" -gt 0 ]]; then
  printf '  FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
