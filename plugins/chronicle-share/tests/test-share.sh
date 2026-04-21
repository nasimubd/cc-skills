#!/usr/bin/env bash
# test-share.sh — self-contained test suite for chronicle-share Phase 5.
#
# Strategy: instead of shelling out to real bundle/sanitize/archive/upload
# (which would need real sessions, real creds, real R2), we copy share.sh
# into a temp dir next to fake sibling scripts. The fakes honor env vars
# to simulate pass/fail at each phase:
#
#   FAIL_BUNDLE=1     → fake bundle.sh exits 2
#   FAIL_SANITIZE=1   → fake sanitize.sh exits 2
#   FAIL_ARCHIVE=1    → fake archive.sh exits 2
#   FAIL_UPLOAD=1     → fake upload.sh exits 3
#   CAPTURE_ARGS=PATH → each fake appends its argv to this file
#
# Usage: tests/test-share.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_SHARE="$HERE/../scripts/share.sh"

if [[ ! -x "$REAL_SHARE" ]]; then
  echo "FATAL: share.sh not found: $REAL_SHARE" >&2; exit 2
fi

PASS=0; FAIL=0
FAILED_NAMES=()
pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }
hdr()  { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------------------
# Shim-sibling builder — sets up a fake scripts dir alongside a copy of
# share.sh. Fakes emit the right outputs so share.sh sees a valid flow,
# but they short-circuit to a predictable fixture.
# ---------------------------------------------------------------------------
mk_shim_dir() {
  local d="$1"
  mkdir -p "$d"
  cp "$REAL_SHARE" "$d/share.sh"
  chmod +x "$d/share.sh"

  # Fake bundle.sh: creates a minimal staging dir + manifest, echoes path.
  cat > "$d/bundle.sh" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${CAPTURE_ARGS:-}" ]] && printf 'bundle: %s\n' "$*" >> "$CAPTURE_ARGS"
if [[ "${FAIL_BUNDLE:-0}" == "1" ]]; then echo "fake bundle failed" >&2; exit 2; fi
staging="$(mktemp -d -t share-test-staging)"
mkdir -p "$staging/sessions" "$staging/sessions-sanitized"
# Minimal manifest shape that sanitize/archive/upload expect.
cat > "$staging/manifest.json" <<EOF
{
  "manifest_version": 1,
  "source": {"project_path": "/fake", "project_encoded": "-fake"},
  "sessions": [],
  "totals": {"session_count": 0, "total_size_bytes": 0},
  "sanitized": false,
  "archived": false
}
EOF
echo "$staging"
FAKE
  chmod +x "$d/bundle.sh"

  # Fake sanitize.sh: flips manifest.sanitized=true.
  cat > "$d/sanitize.sh" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${CAPTURE_ARGS:-}" ]] && printf 'sanitize: %s\n' "$*" >> "$CAPTURE_ARGS"
if [[ "${FAIL_SANITIZE:-0}" == "1" ]]; then echo "fake sanitize failed" >&2; exit 2; fi
staging="$1"
jq '.sanitized=true' "$staging/manifest.json" > "$staging/m.tmp" && mv "$staging/m.tmp" "$staging/manifest.json"
touch "$staging/redaction_report.txt"
echo "$staging"
FAKE
  chmod +x "$d/sanitize.sh"

  # Fake archive.sh: flips manifest.archived=true, creates fake tar.gz.
  cat > "$d/archive.sh" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${CAPTURE_ARGS:-}" ]] && printf 'archive: %s\n' "$*" >> "$CAPTURE_ARGS"
if [[ "${FAIL_ARCHIVE:-0}" == "1" ]]; then echo "fake archive failed" >&2; exit 2; fi
staging="$1"
printf 'fake-tarball' > "$staging/chronicle-share.tar.gz"
printf 'abc  chronicle-share.tar.gz\n' > "$staging/chronicle-share.tar.gz.sha256"
jq '.archived=true | .archive={filename:"chronicle-share.tar.gz", sha256:"abc", size_bytes:12}' \
   "$staging/manifest.json" > "$staging/m.tmp" && mv "$staging/m.tmp" "$staging/manifest.json"
echo "$staging"
FAKE
  chmod +x "$d/archive.sh"

  # Fake upload.sh: if --dry-run, no stdout. Otherwise echo a fake URL +
  # mutate manifest so post.sh's validation guard (uploaded=true) passes.
  cat > "$d/upload.sh" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${CAPTURE_ARGS:-}" ]] && printf 'upload: %s\n' "$*" >> "$CAPTURE_ARGS"
if [[ "${FAIL_UPLOAD:-0}" == "1" ]]; then echo "fake upload failed" >&2; exit 3; fi
# Last positional is STAGING_DIR.
staging=""
for a in "$@"; do [[ "$a" != --* && -d "$a" ]] && staging="$a"; done

dry=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && dry=1; done
if [[ "$dry" -eq 0 ]]; then
  # Mutate manifest so post.sh sees uploaded=true.
  if [[ -n "$staging" && -f "$staging/manifest.json" ]]; then
    jq '.uploaded=true | .upload={
      bucket: "fake-bucket",
      key: "fake/key.tar.gz",
      endpoint_url: "https://fake.r2",
      uploaded_at_utc: "2026-04-21T00:00:00Z",
      presigned_url: "https://fake.r2/bucket/obj?X-Amz-Signature=xxx",
      expires_in_seconds: 604800,
      expires_at_utc: "2026-04-28T00:00:00Z"
    }' "$staging/manifest.json" > "$staging/m.tmp" && mv "$staging/m.tmp" "$staging/manifest.json"
  fi
  echo "https://fake.r2/bucket/obj?X-Amz-Signature=xxx"
fi
FAKE
  chmod +x "$d/upload.sh"

  # Fake post.sh: emits a fake message_id.
  cat > "$d/post.sh" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${CAPTURE_ARGS:-}" ]] && printf 'post: %s\n' "$*" >> "$CAPTURE_ARGS"
if [[ "${FAIL_POST:-0}" == "1" ]]; then echo "fake post failed" >&2; exit 2; fi
echo "999999"
FAKE
  chmod +x "$d/post.sh"
}

# ============================================================================
# Tests — plain arg parsing (no shims needed, uses real share.sh)
# ============================================================================

hdr "Usage + arg parsing (real share.sh)"

# 1. --help exits 0 with usage banner
out=$("$REAL_SHARE" --help 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$out" == *"Usage: share.sh"* ]]; then
  pass "01 --help exits 0 with usage banner"
else
  fail "01 --help" "rc=$rc"
fi

# 2. unknown flag exits 1
"$REAL_SHARE" --bogus >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "02 unknown flag exits 1"; else fail "02" "rc=$rc"; fi

# ============================================================================
# Tests — missing sibling script
# ============================================================================

hdr "Sibling-script validation"

# 3. Missing sibling → exit 1
d=$(mktemp -d -t share-test); cp "$REAL_SHARE" "$d/share.sh"; chmod +x "$d/share.sh"
# no bundle.sh etc. → share.sh should refuse
"$d/share.sh" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "03 missing sibling exits 1"; else fail "03" "rc=$rc"; fi
rm -rf "$d"

# ============================================================================
# Tests — happy path with shimmed siblings
# ============================================================================

hdr "Happy path (shimmed siblings)"

# 4. Real upload path → exit 0 + stdout is fake URL
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
out=$("$d/share.sh" 2>/dev/null); rc=$?
if [[ "$rc" -eq 0 ]]; then pass "04 happy path exits 0"; else fail "04" "rc=$rc"; fi

if [[ "$out" == "https://fake.r2/bucket/obj?X-Amz-Signature=xxx" ]]; then
  pass "05 stdout is presigned URL (exact)"
else
  fail "05 stdout URL" "got: $out"
fi
rm -rf "$d"

# 6. Staging removed on success (no --keep-staging)
# Shim bundle.sh creates a fresh staging each run; we need to capture the path.
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
captured_staging=$("$d/share.sh" 2>&1 | grep -o 'staging = [^ ]*' | awk '{print $NF}' | head -1)
if [[ -n "$captured_staging" && ! -d "$captured_staging" ]]; then
  pass "06 staging removed on success"
else
  fail "06 staging removed" "staging=$captured_staging, still exists=$(test -d "$captured_staging" && echo yes || echo no)"
  [[ -d "$captured_staging" ]] && rm -rf "$captured_staging"
fi
rm -rf "$d"

# 7. --keep-staging preserves staging on success
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
captured_staging=$("$d/share.sh" --keep-staging 2>&1 | grep -o 'staging = [^ ]*' | awk '{print $NF}' | head -1)
if [[ -n "$captured_staging" && -d "$captured_staging" ]]; then
  pass "07 --keep-staging preserves staging on success"
  rm -rf "$captured_staging"
else
  fail "07 --keep-staging" "staging=$captured_staging exists=$(test -d "$captured_staging" && echo yes || echo no)"
fi
rm -rf "$d"

# ============================================================================
# Tests — --dry-run-upload
# ============================================================================

hdr "--dry-run-upload mode"

# 8. --dry-run-upload exits 0, no URL on stdout, staging preserved
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
stderr_log=$(mktemp); stdout_val=$("$d/share.sh" --dry-run-upload 2>"$stderr_log"); rc=$?
if [[ "$rc" -eq 0 ]]; then pass "08 --dry-run-upload exits 0"; else fail "08" "rc=$rc"; fi
if [[ -z "$stdout_val" ]]; then
  pass "09 --dry-run-upload emits no URL on stdout"
else
  fail "09 no URL in dry-run" "got: $stdout_val"
fi

captured_staging=$(grep -o 'staging = [^ ]*' "$stderr_log" | awk '{print $NF}' | head -1)
if [[ -n "$captured_staging" && -d "$captured_staging" ]]; then
  pass "10 --dry-run-upload preserves staging"
  rm -rf "$captured_staging"
else
  fail "10 staging preserved" "staging=$captured_staging"
fi
rm -rf "$d" "$stderr_log"

# ============================================================================
# Tests — argument passthrough
# ============================================================================

hdr "Argument passthrough"

# 11. --project + --limit reach bundle.sh
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" --project /tmp/foo --limit 3 >/dev/null 2>&1
bundle_line=$(grep '^bundle:' "$capture")
if [[ "$bundle_line" == *"--project /tmp/foo"* && "$bundle_line" == *"--limit 3"* ]]; then
  pass "11 --project + --limit forwarded to bundle.sh"
else
  fail "11 bundle args passthrough" "got: $bundle_line"
fi

# 12. sanitize.sh + archive.sh get STAGING positional
sanitize_line=$(grep '^sanitize:' "$capture")
archive_line=$(grep '^archive:' "$capture")
if [[ "$sanitize_line" == *"/share-test-staging"* && "$archive_line" == *"/share-test-staging"* ]]; then
  pass "12 sanitize + archive get STAGING positional"
else
  fail "12" "sanitize=$sanitize_line archive=$archive_line"
fi

# 13. --expires-in + --key-prefix reach upload.sh
upload_line=$(grep '^upload:' "$capture")
rm -f "$capture"
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" --expires-in 3600 --key-prefix "scratch/test" >/dev/null 2>&1
upload_line=$(grep '^upload:' "$capture")
if [[ "$upload_line" == *"--expires-in 3600"* && "$upload_line" == *"--key-prefix scratch/test"* ]]; then
  pass "13 --expires-in + --key-prefix forwarded to upload.sh"
else
  fail "13 upload args passthrough" "got: $upload_line"
fi
rm -f "$capture"

# 14. --dry-run-upload translates to --dry-run in upload.sh call
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" --dry-run-upload >/dev/null 2>&1
upload_line=$(grep '^upload:' "$capture")
if [[ "$upload_line" == *"--dry-run"* ]]; then
  pass "14 --dry-run-upload passes --dry-run to upload.sh"
else
  fail "14 --dry-run translation" "got: $upload_line"
fi

# 15. --keep-staging is NOT forwarded to siblings
keep_in_bundle=$(grep -c 'keep-staging' "$capture" || true)
if [[ "$keep_in_bundle" -eq 0 ]]; then
  pass "15 --keep-staging not forwarded to siblings"
else
  fail "15" "leaked: $keep_in_bundle"
fi
rm -rf "$capture" "$d"

# ============================================================================
# Tests — per-phase failure exit codes + staging preservation
# ============================================================================

hdr "Per-phase failure handling"

# 16. Bundle fails → exit 2
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
FAIL_BUNDLE=1 "$d/share.sh" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "16 bundle failure → exit 2"; else fail "16" "rc=$rc"; fi
rm -rf "$d"

# 17. Sanitize fails → exit 3, staging preserved
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
log=$(mktemp)
FAIL_SANITIZE=1 "$d/share.sh" >/dev/null 2>"$log"; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "17 sanitize failure → exit 3"; else fail "17" "rc=$rc"; fi
leftover=$(grep -o 'staging preserved for debug: [^ ]*' "$log" | awk '{print $NF}' | head -1)
if [[ -n "$leftover" && -d "$leftover" ]]; then
  pass "18 staging preserved on sanitize failure"
  rm -rf "$leftover"
else
  fail "18 staging preserved" "leftover=$leftover"
fi
rm -rf "$d" "$log"

# 19. Archive fails → exit 4, staging preserved
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
log=$(mktemp)
FAIL_ARCHIVE=1 "$d/share.sh" >/dev/null 2>"$log"; rc=$?
if [[ "$rc" -eq 4 ]]; then pass "19 archive failure → exit 4"; else fail "19" "rc=$rc"; fi
leftover=$(grep -o 'staging preserved for debug: [^ ]*' "$log" | awk '{print $NF}' | head -1)
if [[ -n "$leftover" && -d "$leftover" ]]; then
  pass "20 staging preserved on archive failure"
  rm -rf "$leftover"
else
  fail "20" "leftover=$leftover"
fi
rm -rf "$d" "$log"

# 21. Upload fails → exit 5, staging preserved
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
log=$(mktemp)
FAIL_UPLOAD=1 "$d/share.sh" >/dev/null 2>"$log"; rc=$?
if [[ "$rc" -eq 5 ]]; then pass "21 upload failure → exit 5"; else fail "21" "rc=$rc"; fi
leftover=$(grep -o 'staging preserved for debug: [^ ]*' "$log" | awk '{print $NF}' | head -1)
if [[ -n "$leftover" && -d "$leftover" ]]; then
  pass "22 staging preserved on upload failure"
  rm -rf "$leftover"
else
  fail "22" "leftover=$leftover"
fi
rm -rf "$d" "$log"

# ============================================================================
# Phase 6 orchestration
# ============================================================================

hdr "Phase 6 chaining"

# 23. post.sh is called by default
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" >/dev/null 2>&1
if grep -q '^post:' "$capture"; then
  pass "23 post.sh invoked by default"
else
  fail "23 post.sh default call" "no post: line in capture"
fi
rm -f "$capture"; rm -rf "$d"

# 24. --no-post skips post.sh
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" --no-post >/dev/null 2>&1
if ! grep -q '^post:' "$capture"; then
  pass "24 --no-post skips post.sh"
else
  fail "24 --no-post" "post.sh was called: $(grep '^post:' "$capture")"
fi
rm -f "$capture"; rm -rf "$d"

# 25. --post-chat-id + --post-topic-id forwarded
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" \
  --post-chat-id 7730224133 --post-topic-id 1 >/dev/null 2>&1
post_line=$(grep '^post:' "$capture")
if [[ "$post_line" == *"--chat-id 7730224133"* && "$post_line" == *"--topic-id 1"* ]]; then
  pass "25 --post-chat-id + --post-topic-id forwarded to post.sh"
else
  fail "25 post passthrough" "got: $post_line"
fi
rm -f "$capture"; rm -rf "$d"

# 26. --dry-run-upload implies --no-post
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
capture=$(mktemp)
CAPTURE_ARGS="$capture" "$d/share.sh" --dry-run-upload >/dev/null 2>&1
if ! grep -q '^post:' "$capture"; then
  pass "26 --dry-run-upload implies --no-post"
else
  fail "26 dry-run implies no-post" "post.sh was called"
fi
rm -f "$capture"; rm -rf "$d"

# 27. post.sh fails → exit 6, staging preserved
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
log=$(mktemp)
FAIL_POST=1 "$d/share.sh" >/dev/null 2>"$log"; rc=$?
if [[ "$rc" -eq 6 ]]; then pass "27 post failure → exit 6"; else fail "27" "rc=$rc"; fi
leftover=$(grep -o 'staging preserved for debug: [^ ]*' "$log" | awk '{print $NF}' | head -1)
if [[ -n "$leftover" && -d "$leftover" ]]; then
  pass "28 staging preserved on post failure"
  rm -rf "$leftover"
else
  fail "28" "leftover=$leftover"
fi
rm -rf "$d" "$log"

# 29. With post enabled, stdout is still the presigned URL (not message_id)
d=$(mktemp -d -t share-test); mk_shim_dir "$d"
out=$("$d/share.sh" 2>/dev/null)
if [[ "$out" == "https://fake.r2/bucket/obj?X-Amz-Signature=xxx" ]]; then
  pass "29 with post: stdout remains presigned URL"
else
  fail "29 stdout" "got: $out"
fi
rm -rf "$d"

# ============================================================================
# Summary
# ============================================================================
total=$((PASS+FAIL))
printf '\n'
printf '================================================================\n'
printf '  Phase 5 share.sh — %d/%d passed\n' "$PASS" "$total"
printf '================================================================\n'
if [[ "$FAIL" -gt 0 ]]; then
  printf '  FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
