#!/usr/bin/env bash
# test-archive.sh — self-contained test suite for chronicle-share Phase 3.
#
# Usage: tests/test-archive.sh
# Returns non-zero if any case fails. Mocks a post-sanitize staging dir
# (no real Claude Code JSONL or upstream sanitizer required).

set -uo pipefail   # NOT -e: each test asserts its own outcome

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/archive.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FATAL: archive.sh not found or not executable: $SCRIPT" >&2
  exit 2
fi

# --- minimal pretty output --------------------------------------------------
PASS=0
FAIL=0
FAILED_NAMES=()

pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }
hdr()  { printf '\n=== %s ===\n' "$1"; }

# --- helpers ----------------------------------------------------------------

# Create a fake post-sanitize staging dir at $1 with $2 sessions.
# Produces the shape that sanitize.sh would have left behind.
mk_staged() {
  local dir="$1"
  local n="${2:-2}"

  mkdir -p "$dir/sessions" "$dir/sessions-sanitized"

  # Build manifest entries for $n sessions.
  local entries='[]'
  local total_size=0
  for i in $(seq 1 "$n"); do
    local sid="session-$i-uuid"
    local fn="$sid.jsonl"
    local content="{\"type\":\"user\",\"text\":\"hello $i\"}"$'\n'"{\"type\":\"assistant\",\"text\":\"world $i\"}"$'\n'
    printf '%s' "$content" > "$dir/sessions/$fn"
    printf '%s' "$content" > "$dir/sessions-sanitized/$fn"

    local size_raw
    size_raw=$(stat -f %z "$dir/sessions/$fn")
    local size_san
    size_san=$(stat -f %z "$dir/sessions-sanitized/$fn")
    local sha_raw
    sha_raw=$(shasum -a 256 "$dir/sessions/$fn" | awk '{print $1}')
    local sha_san
    sha_san=$(shasum -a 256 "$dir/sessions-sanitized/$fn" | awk '{print $1}')
    total_size=$((total_size + size_raw))

    entries=$(jq \
      --arg sid "$sid" --arg fn "$fn" \
      --argjson sz "$size_raw" --argjson lc 2 \
      --arg mt "2026-04-21T00:00:00Z" --arg sha "$sha_raw" \
      --argjson ssz "$size_san" --argjson slc 2 --arg ssha "$sha_san" \
      '. + [{
        session_id: $sid, filename: $fn,
        size_bytes: $sz, line_count: $lc,
        mtime_utc: $mt, sha256: $sha,
        sanitized_size_bytes: $ssz, sanitized_line_count: $slc,
        sanitized_sha256: $ssha
      }]' <<<"$entries")
  done

  # Fake redaction report
  cat > "$dir/redaction_report.txt" <<EOF
v2 Redaction Report — fake
Output: fake
Files: $n   Lines: $((n*2))   Redactions: 0

Per-pattern counts (sorted by frequency):
  (none)
EOF

  # Fake manifest with sanitized=true, archived=false
  jq -n \
    --arg gen_at "2026-04-21T00:00:00Z" \
    --arg proj "/tmp/fake-project" \
    --arg enc "-tmp-fake-project" \
    --arg host "testhost" --arg user "testuser" \
    --argjson total_sz "$total_size" \
    --argjson sessions "$entries" \
    --argjson n "$n" \
    '{
      manifest_version: 1,
      generated_at_utc: $gen_at,
      generated_by: "chronicle-share/bundle.sh",
      source: {project_path:$proj, project_encoded:$enc, host:$host, claude_user:$user},
      sessions: $sessions,
      totals: {session_count:$n, total_size_bytes:$total_sz},
      sanitized: true,
      archived: false,
      sanitization: {
        sanitized_at_utc: "2026-04-21T00:00:00Z",
        sanitizer_path: "/fake/sanitize_sessions.py",
        sanitizer_sha256: "aaaaaaaaaaaaaaaa",
        report_path: "\($enc)/redaction_report.txt"
      },
      redactions: {total: 0, by_pattern: {}}
    }' > "$dir/manifest.json"
}

# Spawn a disposable staging dir, echo its path.
mk_tmp() {
  mktemp -d -t chronicle-archive-test
}

# ============================================================================
# Tests
# ============================================================================

hdr "Usage + arg parsing"

# 1. --help prints usage and exits 0
out=$("$SCRIPT" --help 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$out" == *"Usage: archive.sh"* ]]; then
  pass "01 --help exits 0 and prints usage"
else
  fail "01 --help exits 0 and prints usage" "rc=$rc, out=$out"
fi

# 2. Missing STAGING_DIR exits 1
"$SCRIPT" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "02 missing STAGING_DIR exits 1"
else
  fail "02 missing STAGING_DIR exits 1" "rc=$rc"
fi

# 3. Unknown flag exits 1
"$SCRIPT" --bogus /tmp >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "03 unknown flag exits 1"
else
  fail "03 unknown flag exits 1" "rc=$rc"
fi

# 4. Two positional args exit 1
"$SCRIPT" /tmp/a /tmp/b >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "04 two positional args exits 1"
else
  fail "04 two positional args exits 1" "rc=$rc"
fi

hdr "Validation guards"

# 5. Nonexistent STAGING_DIR exits 1
"$SCRIPT" /tmp/definitely-not-here-$RANDOM >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "05 nonexistent staging dir exits 1"
else
  fail "05 nonexistent staging dir exits 1" "rc=$rc"
fi

# 6. Staging without manifest.json exits 1
d=$(mk_tmp); mkdir -p "$d/sessions-sanitized"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "06 missing manifest.json exits 1"
else
  fail "06 missing manifest.json exits 1" "rc=$rc"
fi
rm -rf "$d"

# 7. Staging with invalid JSON manifest exits 1
d=$(mk_tmp); mkdir -p "$d/sessions-sanitized"
echo "not json {" > "$d/manifest.json"
touch "$d/redaction_report.txt"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "07 invalid JSON manifest exits 1"
else
  fail "07 invalid JSON manifest exits 1" "rc=$rc"
fi
rm -rf "$d"

# 8. Unsanitized manifest (sanitized=false) exits 1
d=$(mk_tmp); mk_staged "$d" 1
jq '.sanitized = false' "$d/manifest.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "08 sanitized=false refused (exits 1)"
else
  fail "08 sanitized=false refused (exits 1)" "rc=$rc"
fi
rm -rf "$d"

# 9. Missing sessions-sanitized/ dir exits 1
d=$(mk_tmp); mk_staged "$d" 1; rm -rf "$d/sessions-sanitized"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "09 missing sessions-sanitized/ exits 1"
else
  fail "09 missing sessions-sanitized/ exits 1" "rc=$rc"
fi
rm -rf "$d"

# 10. Missing redaction_report.txt exits 1
d=$(mk_tmp); mk_staged "$d" 1; rm -f "$d/redaction_report.txt"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "10 missing redaction_report.txt exits 1"
else
  fail "10 missing redaction_report.txt exits 1" "rc=$rc"
fi
rm -rf "$d"

# 11. Empty sessions-sanitized/ exits 1
d=$(mk_tmp); mk_staged "$d" 1; rm -f "$d/sessions-sanitized"/*.jsonl
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "11 empty sessions-sanitized/ exits 1"
else
  fail "11 empty sessions-sanitized/ exits 1" "rc=$rc"
fi
rm -rf "$d"

# 12. Count mismatch exits 1 (manifest says 2, only 1 file present)
d=$(mk_tmp); mk_staged "$d" 2; rm -f "$d/sessions-sanitized/session-2-uuid.jsonl"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "12 manifest/file count mismatch exits 1"
else
  fail "12 manifest/file count mismatch exits 1" "rc=$rc"
fi
rm -rf "$d"

hdr "Happy path"

# 13. Happy path: archive + sidecar + updated manifest all created
d=$(mk_tmp); mk_staged "$d" 3
out=$("$SCRIPT" "$d" 2>/dev/null); rc=$?
if [[ "$rc" -eq 0 && "$out" == "$d" ]]; then
  pass "13 happy path returns 0 and echoes STAGING_DIR"
else
  fail "13 happy path returns 0 and echoes STAGING_DIR" "rc=$rc, out=$out"
fi

if [[ -f "$d/chronicle-share.tar.gz" ]]; then
  pass "14 archive file created"
else
  fail "14 archive file created" "missing $d/chronicle-share.tar.gz"
fi

if [[ -f "$d/chronicle-share.tar.gz.sha256" ]]; then
  pass "15 sidecar sha256 file created"
else
  fail "15 sidecar sha256 file created" "missing .sha256"
fi

hdr "Outer manifest"

# 16. archived flipped to true
archived=$(jq -r '.archived' "$d/manifest.json")
if [[ "$archived" == "true" ]]; then
  pass "16 outer manifest.archived=true"
else
  fail "16 outer manifest.archived=true" "got: $archived"
fi

# 17. archive subfield has all expected keys
keys=$(jq -r '.archive | keys | sort | join(",")' "$d/manifest.json")
expected="contents,created_at_utc,filename,format,sha256,size_bytes"
if [[ "$keys" == "$expected" ]]; then
  pass "17 outer manifest.archive has all 6 keys"
else
  fail "17 outer manifest.archive has all 6 keys" "got: $keys"
fi

# 18. archive.filename matches on-disk artifact
fn=$(jq -r '.archive.filename' "$d/manifest.json")
if [[ "$fn" == "chronicle-share.tar.gz" ]]; then
  pass "18 archive.filename = chronicle-share.tar.gz"
else
  fail "18 archive.filename" "got: $fn"
fi

# 19. archive.format = tar.gz
fmt=$(jq -r '.archive.format' "$d/manifest.json")
if [[ "$fmt" == "tar.gz" ]]; then
  pass "19 archive.format = tar.gz"
else
  fail "19 archive.format" "got: $fmt"
fi

# 20. archive.size_bytes matches file size
declared_size=$(jq -r '.archive.size_bytes' "$d/manifest.json")
actual_size=$(stat -f %z "$d/chronicle-share.tar.gz")
if [[ "$declared_size" == "$actual_size" ]]; then
  pass "20 archive.size_bytes matches file size"
else
  fail "20 archive.size_bytes matches file size" "declared=$declared_size actual=$actual_size"
fi

# 21. archive.sha256 matches shasum of file
declared_sha=$(jq -r '.archive.sha256' "$d/manifest.json")
actual_sha=$(shasum -a 256 "$d/chronicle-share.tar.gz" | awk '{print $1}')
if [[ "$declared_sha" == "$actual_sha" ]]; then
  pass "21 archive.sha256 matches shasum of file"
else
  fail "21 archive.sha256 matches shasum of file" "declared=$declared_sha actual=$actual_sha"
fi

hdr "Sidecar sha256"

# 22. Sidecar content matches: "<sha>  chronicle-share.tar.gz"
sidecar_content=$(cat "$d/chronicle-share.tar.gz.sha256")
expected_line="$actual_sha  chronicle-share.tar.gz"
if [[ "$sidecar_content" == "$expected_line" ]]; then
  pass "22 sidecar line = <sha>  chronicle-share.tar.gz"
else
  fail "22 sidecar line" "got: $sidecar_content"
fi

# 23. shasum --check on sidecar passes
if (cd "$d" && shasum -a 256 -c chronicle-share.tar.gz.sha256 >/dev/null 2>&1); then
  pass "23 shasum -c sidecar passes"
else
  fail "23 shasum -c sidecar passes" "verification failed"
fi

hdr "Archive contents"

# 24. Archive is a valid gzip'd tar
if (cd "$d" && tar -tzf chronicle-share.tar.gz >/dev/null 2>&1); then
  pass "24 archive is a valid tar.gz"
else
  fail "24 archive is a valid tar.gz" "tar -tzf failed"
fi

# 25. Archive contains manifest.json + sessions-sanitized/*.jsonl + report
entries=$(cd "$d" && tar -tzf chronicle-share.tar.gz | sort)
expected_entries=$(printf 'manifest.json\nredaction_report.txt\nsessions-sanitized/\nsessions-sanitized/session-1-uuid.jsonl\nsessions-sanitized/session-2-uuid.jsonl\nsessions-sanitized/session-3-uuid.jsonl')
# BSD tar may or may not emit the directory entry; accept both shapes.
if [[ "$entries" == *"manifest.json"* && \
      "$entries" == *"redaction_report.txt"* && \
      "$entries" == *"sessions-sanitized/session-1-uuid.jsonl"* && \
      "$entries" == *"sessions-sanitized/session-2-uuid.jsonl"* && \
      "$entries" == *"sessions-sanitized/session-3-uuid.jsonl"* ]]; then
  pass "25 archive contents: manifest + 3 jsonl + report"
else
  fail "25 archive contents" "got: $entries"
fi

# 26. Archive does NOT contain raw sessions/
if [[ "$entries" != *"sessions/session"* ]]; then
  pass "26 archive excludes raw sessions/ dir"
else
  fail "26 archive excludes raw sessions/ dir" "leaked: $entries"
fi

hdr "Embedded manifest"

# 27. Extract + inspect embedded manifest
extract=$(mk_tmp)
(cd "$extract" && tar -xzf "$d/chronicle-share.tar.gz")
inner_archived=$(jq -r '.archived' "$extract/manifest.json")
inner_has_archive=$(jq -r 'has("archive")' "$extract/manifest.json")
if [[ "$inner_archived" == "true" && "$inner_has_archive" == "true" ]]; then
  pass "27 embedded manifest has archived=true + archive subfield"
else
  fail "27 embedded manifest" "archived=$inner_archived has_archive=$inner_has_archive"
fi

# 28. Embedded manifest has filename/format/contents/created_at_utc but NO size_bytes/sha256
inner_keys=$(jq -r '.archive | keys | sort | join(",")' "$extract/manifest.json")
if [[ "$inner_keys" == "contents,created_at_utc,filename,format" ]]; then
  pass "28 embedded manifest.archive omits self-referential size/sha256"
else
  fail "28 embedded manifest.archive omits self-referential size/sha256" "got: $inner_keys"
fi

# 29. Extracted sessions-sanitized/ round-trips byte-for-byte
# Compare one of the sanitized files pre- vs post-archive.
if diff -q "$d/sessions-sanitized/session-1-uuid.jsonl" \
           "$extract/sessions-sanitized/session-1-uuid.jsonl" >/dev/null 2>&1; then
  pass "29 sanitized JSONL round-trips through archive unchanged"
else
  fail "29 sanitized JSONL round-trips through archive unchanged" "diff detected"
fi
rm -rf "$extract"

hdr "Idempotency + --force"

# 30. Re-archive without --force refused (exit 1)
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "30 re-archive without --force refused"
else
  fail "30 re-archive without --force refused" "rc=$rc"
fi

# 31. Re-archive with --force succeeds
old_sha=$(jq -r '.archive.sha256' "$d/manifest.json")
"$SCRIPT" --force "$d" >/dev/null 2>&1; rc=$?
new_sha=$(jq -r '.archive.sha256' "$d/manifest.json")
if [[ "$rc" -eq 0 ]]; then
  pass "31 --force re-archive succeeds"
else
  fail "31 --force re-archive succeeds" "rc=$rc"
fi

# 32. Even after --force, sidecar still matches archive
if (cd "$d" && shasum -a 256 -c chronicle-share.tar.gz.sha256 >/dev/null 2>&1); then
  pass "32 after --force: sidecar still verifies"
else
  fail "32 after --force: sidecar still verifies" "verification failed"
fi

rm -rf "$d"

# ============================================================================
# Summary
# ============================================================================
total=$((PASS+FAIL))
printf '\n'
printf '================================================================\n'
printf '  Phase 3 archive.sh — %d/%d passed\n' "$PASS" "$total"
printf '================================================================\n'
if [[ "$FAIL" -gt 0 ]]; then
  printf '  FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
