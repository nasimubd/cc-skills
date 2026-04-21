#!/usr/bin/env bash
# test-upload.sh — self-contained test suite for chronicle-share Phase 4.
#
# Mocks `op` (1Password) and `aws` (AWS CLI) via PATH shims so tests run
# without real credentials or network access. The shim scripts honor env
# vars to simulate failure modes:
#
#   MOCK_OP_FAIL=1           → op exits 1 (credential fetch failure)
#   MOCK_AWS_CP_FAIL=1       → aws s3 cp exits 1
#   MOCK_AWS_PRESIGN_FAIL=1  → aws s3 presign exits 1
#
# Usage: tests/test-upload.sh
# Returns non-zero if any case fails.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/upload.sh"
ARCHIVE_SCRIPT="$HERE/../scripts/archive.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FATAL: upload.sh not found or not executable: $SCRIPT" >&2
  exit 2
fi

PASS=0; FAIL=0
FAILED_NAMES=()
pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }
hdr()  { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------------------
# Shim setup — mock op + aws on PATH
# ---------------------------------------------------------------------------
SHIM_DIR="$(mktemp -d -t chronicle-upload-shims)"

cat > "$SHIM_DIR/op" <<'SHIM_EOF'
#!/usr/bin/env bash
# Mock 1Password CLI. Returns fake credentials for known fields.
# Fail if MOCK_OP_FAIL=1.
if [[ "${MOCK_OP_FAIL:-0}" == "1" ]]; then
  echo "mock: auth failure" >&2
  exit 1
fi

case "$1" in
  read)
    ref="$2"
    case "$ref" in
      *"/username")     echo "FAKE_ACCESS_KEY_ID_123" ;;
      *"/credential")   echo "FAKE_SECRET_ACCESS_KEY_XYZ" ;;
      *"/endpoint_url") echo "https://fake.r2.cloudflarestorage.com" ;;
      *"/bucket_name")  echo "fake-test-bucket" ;;
      *) echo "mock: unknown field: $ref" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "mock op: unsupported: $*" >&2
    exit 1
    ;;
esac
SHIM_EOF

cat > "$SHIM_DIR/aws" <<'SHIM_EOF'
#!/usr/bin/env bash
# Mock AWS CLI.
#   aws s3 cp SRC DST --endpoint-url ...         → simulate upload
#   aws s3 presign s3://... --expires-in N       → emit fake signed URL
if [[ "$1" == "s3" ]]; then
  shift
  case "$1" in
    cp)
      if [[ "${MOCK_AWS_CP_FAIL:-0}" == "1" ]]; then
        echo "mock aws: cp failed" >&2
        exit 1
      fi
      echo "upload: ${2} -> ${3}"
      exit 0
      ;;
    presign)
      if [[ "${MOCK_AWS_PRESIGN_FAIL:-0}" == "1" ]]; then
        echo "mock aws: presign failed" >&2
        exit 1
      fi
      s3url="$2"
      exp=604800
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --expires-in) exp="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      echo "https://fake.r2.cloudflarestorage.com/FAKE-URL?X-Amz-Expires=${exp}&X-Amz-Signature=abc123"
      exit 0
      ;;
    *) echo "mock aws: unsupported s3 subcmd: $1" >&2; exit 1 ;;
  esac
fi
exit 1
SHIM_EOF

chmod +x "$SHIM_DIR/op" "$SHIM_DIR/aws"

cleanup() { rm -rf "$SHIM_DIR"; }
trap cleanup EXIT

# Prepend shim dir to PATH — shims win over real op/aws
export PATH="$SHIM_DIR:$PATH"

# ---------------------------------------------------------------------------
# Stage builder — produces a full post-archive staging dir without needing
# the real bundle.sh/sanitize.sh pipeline.
# ---------------------------------------------------------------------------
mk_staged_archived() {
  local dir="$1"
  local n="${2:-1}"

  mkdir -p "$dir/sessions" "$dir/sessions-sanitized"

  local entries='[]'
  local total_size=0
  for i in $(seq 1 "$n"); do
    local sid="session-$i-uuid"
    local fn="$sid.jsonl"
    local content="{\"type\":\"user\",\"text\":\"hello $i\"}"$'\n'
    printf '%s' "$content" > "$dir/sessions/$fn"
    printf '%s' "$content" > "$dir/sessions-sanitized/$fn"
    local size_raw size_san sha_raw sha_san
    size_raw=$(stat -f %z "$dir/sessions/$fn")
    size_san=$(stat -f %z "$dir/sessions-sanitized/$fn")
    sha_raw=$(shasum -a 256 "$dir/sessions/$fn" | awk '{print $1}')
    sha_san=$(shasum -a 256 "$dir/sessions-sanitized/$fn" | awk '{print $1}')
    total_size=$((total_size + size_raw))
    entries=$(jq \
      --arg sid "$sid" --arg fn "$fn" \
      --argjson sz "$size_raw" --argjson lc 1 \
      --arg mt "2026-04-21T00:00:00Z" --arg sha "$sha_raw" \
      --argjson ssz "$size_san" --argjson slc 1 --arg ssha "$sha_san" \
      '. + [{session_id:$sid, filename:$fn, size_bytes:$sz, line_count:$lc,
             mtime_utc:$mt, sha256:$sha,
             sanitized_size_bytes:$ssz, sanitized_line_count:$slc,
             sanitized_sha256:$ssha}]' <<<"$entries")
  done

  cat > "$dir/redaction_report.txt" <<EOF
v2 Redaction Report — fake
Files: $n   Lines: $n   Redactions: 0
EOF

  jq -n \
    --arg gen_at "2026-04-21T00:00:00Z" \
    --arg proj "/tmp/fake-proj" --arg enc "-tmp-fake-proj" \
    --arg host "h" --arg user "u" \
    --argjson total_sz "$total_size" \
    --argjson sessions "$entries" --argjson n "$n" \
    '{
      manifest_version:1, generated_at_utc:$gen_at,
      generated_by:"chronicle-share/bundle.sh",
      source:{project_path:$proj, project_encoded:$enc, host:$host, claude_user:$user},
      sessions:$sessions,
      totals:{session_count:$n, total_size_bytes:$total_sz},
      sanitized:true, archived:false,
      sanitization:{sanitized_at_utc:"2026-04-21T00:00:00Z",
                    sanitizer_path:"/fake/s.py", sanitizer_sha256:"aaaa",
                    report_path:"fake"},
      redactions:{total:0, by_pattern:{}}
    }' > "$dir/manifest.json"

  # Actually run archive.sh so the staging is fully Phase-3 done
  "$ARCHIVE_SCRIPT" "$dir" >/dev/null 2>&1
}

mk_tmp() { mktemp -d -t chronicle-upload-test; }

# ============================================================================
# Tests
# ============================================================================

hdr "Usage + arg parsing"

# 1. --help exits 0
out=$("$SCRIPT" --help 2>&1); rc=$?
if [[ "$rc" -eq 0 && "$out" == *"Usage: upload.sh"* ]]; then
  pass "01 --help exits 0 and prints usage"
else
  fail "01 --help" "rc=$rc"
fi

# 2. Missing STAGING_DIR → exit 1
"$SCRIPT" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "02 missing STAGING_DIR exits 1"; else fail "02" "rc=$rc"; fi

# 3. Unknown flag → exit 1
"$SCRIPT" --bogus /tmp >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "03 unknown flag exits 1"; else fail "03" "rc=$rc"; fi

# 4. Two positional → exit 1
"$SCRIPT" /tmp/a /tmp/b >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "04 two positional args exits 1"; else fail "04" "rc=$rc"; fi

# 5. --expires-in non-numeric → exit 1
"$SCRIPT" --expires-in abc /tmp >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "05 --expires-in non-numeric exits 1"; else fail "05" "rc=$rc"; fi

# 6. --expires-in = 0 → exit 1
"$SCRIPT" --expires-in 0 /tmp >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "06 --expires-in=0 exits 1"; else fail "06" "rc=$rc"; fi

# 7. --expires-in > 604800 → exit 1
"$SCRIPT" --expires-in 999999 /tmp >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "07 --expires-in>604800 exits 1"; else fail "07" "rc=$rc"; fi

hdr "Validation guards"

# 8. Nonexistent STAGING_DIR → exit 1
"$SCRIPT" /tmp/definitely-absent-$RANDOM >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "08 nonexistent staging exits 1"; else fail "08" "rc=$rc"; fi

# 9. Missing manifest → exit 1
d=$(mk_tmp); mkdir -p "$d/sessions-sanitized"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "09 missing manifest exits 1"; else fail "09" "rc=$rc"; fi
rm -rf "$d"

# 10. Invalid JSON manifest → exit 1
d=$(mk_tmp); echo "bad {" > "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "10 invalid JSON manifest exits 1"; else fail "10" "rc=$rc"; fi
rm -rf "$d"

# 11. Unarchived manifest (archived=false) → exit 1
d=$(mk_tmp); mk_staged_archived "$d" 1
jq '.archived=false' "$d/manifest.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "11 archived=false refused (exits 1)"; else fail "11" "rc=$rc"; fi
rm -rf "$d"

# 12. Missing archive tar.gz → exit 1
d=$(mk_tmp); mk_staged_archived "$d" 1; rm -f "$d/chronicle-share.tar.gz"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "12 missing archive exits 1"; else fail "12" "rc=$rc"; fi
rm -rf "$d"

# 13. Missing sidecar → exit 1
d=$(mk_tmp); mk_staged_archived "$d" 1; rm -f "$d/chronicle-share.tar.gz.sha256"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "13 missing sidecar exits 1"; else fail "13" "rc=$rc"; fi
rm -rf "$d"

# 14. Sidecar mismatch (corrupt archive) → exit 1
d=$(mk_tmp); mk_staged_archived "$d" 1
printf 'corrupt' >> "$d/chronicle-share.tar.gz"   # tamper
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "14 corrupt archive (sidecar mismatch) exits 1"; else fail "14" "rc=$rc"; fi
rm -rf "$d"

# 15. Manifest missing archive.sha256 → exit 1
d=$(mk_tmp); mk_staged_archived "$d" 1
jq 'del(.archive.sha256)' "$d/manifest.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/manifest.json"
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "15 manifest missing archive.sha256 exits 1"; else fail "15" "rc=$rc"; fi
rm -rf "$d"

hdr "Credential load (1Password shim)"

# 16. op fails → exit 2
d=$(mk_tmp); mk_staged_archived "$d" 1
MOCK_OP_FAIL=1 "$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "16 op failure exits 2"; else fail "16" "rc=$rc"; fi
rm -rf "$d"

hdr "Happy path (shimmed aws)"

d=$(mk_tmp); mk_staged_archived "$d" 2
out=$("$SCRIPT" "$d" 2>/dev/null); rc=$?

# 17. Returns 0 on success
if [[ "$rc" -eq 0 ]]; then pass "17 happy path exits 0"; else fail "17" "rc=$rc"; fi

# 18. Stdout = presigned URL (single line)
if [[ "$out" == https://*"X-Amz-Signature"* ]]; then
  pass "18 stdout = presigned URL"
else
  fail "18 stdout = presigned URL" "got: $out"
fi

# 19. manifest.uploaded=true
if [[ "$(jq -r '.uploaded' "$d/manifest.json")" == "true" ]]; then
  pass "19 manifest.uploaded=true"
else
  fail "19 manifest.uploaded=true" "got: $(jq -r '.uploaded' "$d/manifest.json")"
fi

# 20. upload has all 7 keys
keys=$(jq -r '.upload | keys | sort | join(",")' "$d/manifest.json")
expected="bucket,endpoint_url,expires_at_utc,expires_in_seconds,key,presigned_url,uploaded_at_utc"
if [[ "$keys" == "$expected" ]]; then
  pass "20 upload subfield has all 7 keys"
else
  fail "20 upload keys" "got: $keys"
fi

# 21. upload.bucket from shim
bucket=$(jq -r '.upload.bucket' "$d/manifest.json")
if [[ "$bucket" == "fake-test-bucket" ]]; then
  pass "21 upload.bucket from shim"
else
  fail "21 upload.bucket" "got: $bucket"
fi

# 22. upload.key has correct shape: chronicles/<enc>/<ts>-<shortsha>.tar.gz
key=$(jq -r '.upload.key' "$d/manifest.json")
if [[ "$key" =~ ^chronicles/-tmp-fake-proj/.*-[a-f0-9]{8}\.tar\.gz$ ]]; then
  pass "22 upload.key shape correct"
else
  fail "22 upload.key shape" "got: $key"
fi

# 23. upload.expires_in_seconds = 604800 default
exp=$(jq -r '.upload.expires_in_seconds' "$d/manifest.json")
if [[ "$exp" == "604800" ]]; then
  pass "23 upload.expires_in_seconds=604800 default"
else
  fail "23 upload.expires_in_seconds" "got: $exp"
fi

# 24. upload.presigned_url matches stdout
url_in_manifest=$(jq -r '.upload.presigned_url' "$d/manifest.json")
if [[ "$url_in_manifest" == "$out" ]]; then
  pass "24 upload.presigned_url = stdout"
else
  fail "24 url match" "stdout=$out, manifest=$url_in_manifest"
fi

# 25. expires_at_utc = uploaded_at_utc + expires_in_seconds
up_at=$(jq -r '.upload.uploaded_at_utc' "$d/manifest.json")
exp_at=$(jq -r '.upload.expires_at_utc' "$d/manifest.json")
up_ep=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$up_at" +%s)
exp_ep=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$exp_at" +%s)
delta=$((exp_ep - up_ep))
if [[ "$delta" -eq 604800 ]]; then
  pass "25 expires_at_utc - uploaded_at_utc = 604800 sec"
else
  fail "25 expiry delta" "got: $delta"
fi

hdr "Idempotency + --force"

# 26. Re-upload without --force → exit 1
"$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 1 ]]; then pass "26 re-upload without --force refused"; else fail "26" "rc=$rc"; fi

# 27. Re-upload with --force → exit 0
old_uploaded_at=$(jq -r '.upload.uploaded_at_utc' "$d/manifest.json")
sleep 1
"$SCRIPT" --force "$d" >/dev/null 2>&1; rc=$?
new_uploaded_at=$(jq -r '.upload.uploaded_at_utc' "$d/manifest.json")
if [[ "$rc" -eq 0 && "$old_uploaded_at" != "$new_uploaded_at" ]]; then
  pass "27 --force re-upload succeeds with new timestamp"
else
  fail "27 --force re-upload" "rc=$rc, same_ts=$(("$old_uploaded_at" = "$new_uploaded_at"))"
fi

rm -rf "$d"

hdr "Custom --expires-in + --key-prefix"

# 28. --expires-in 3600 → reflected in manifest
d=$(mk_tmp); mk_staged_archived "$d" 1
"$SCRIPT" --expires-in 3600 "$d" >/dev/null 2>&1
exp=$(jq -r '.upload.expires_in_seconds' "$d/manifest.json")
if [[ "$exp" == "3600" ]]; then pass "28 --expires-in 3600 honored"; else fail "28" "got: $exp"; fi
rm -rf "$d"

# 29. --key-prefix custom → reflected in key
d=$(mk_tmp); mk_staged_archived "$d" 1
"$SCRIPT" --key-prefix "test/scratch" "$d" >/dev/null 2>&1
key=$(jq -r '.upload.key' "$d/manifest.json")
if [[ "$key" == test/scratch/* ]]; then pass "29 --key-prefix honored"; else fail "29" "got: $key"; fi
rm -rf "$d"

hdr "AWS failure modes (shimmed)"

# 30. aws s3 cp fails → exit 3
d=$(mk_tmp); mk_staged_archived "$d" 1
MOCK_AWS_CP_FAIL=1 "$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "30 aws s3 cp failure exits 3"; else fail "30" "rc=$rc"; fi
# Verify manifest NOT mutated on failure (.uploaded absent or false, .upload absent)
up_after=$(jq -r '.uploaded // false' "$d/manifest.json")
has_upload=$(jq -r 'has("upload")' "$d/manifest.json")
if [[ "$up_after" == "false" && "$has_upload" == "false" ]]; then
  pass "31 manifest unchanged when aws cp fails"
else
  fail "31 manifest unchanged" "uploaded=$up_after, has_upload=$has_upload"
fi
rm -rf "$d"

# 32. aws s3 presign fails → exit 3
d=$(mk_tmp); mk_staged_archived "$d" 1
MOCK_AWS_PRESIGN_FAIL=1 "$SCRIPT" "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 3 ]]; then pass "32 aws s3 presign failure exits 3"; else fail "32" "rc=$rc"; fi
rm -rf "$d"

hdr "--dry-run mode"

# 33. --dry-run returns 0
d=$(mk_tmp); mk_staged_archived "$d" 1
out=$("$SCRIPT" --dry-run "$d" 2>&1); rc=$?
if [[ "$rc" -eq 0 ]]; then pass "33 --dry-run exits 0"; else fail "33" "rc=$rc"; fi

# 34. --dry-run does NOT mutate manifest (.uploaded absent or false)
if [[ "$(jq -r '.uploaded // false' "$d/manifest.json")" == "false" ]]; then
  pass "34 --dry-run leaves manifest.uploaded unset/false"
else
  fail "34 dry-run mutated manifest" "got: $(jq -r '.uploaded // false' "$d/manifest.json")"
fi

# 35. --dry-run does NOT add upload subfield
has_upload=$(jq -r 'has("upload")' "$d/manifest.json")
if [[ "$has_upload" == "false" ]]; then
  pass "35 --dry-run does not add upload subfield"
else
  fail "35" "got: $has_upload"
fi

# 36. --dry-run still fails if op creds can't load
MOCK_OP_FAIL=1 "$SCRIPT" --dry-run "$d" >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]]; then pass "36 --dry-run validates creds (exit 2 on op fail)"; else fail "36" "rc=$rc"; fi

# 37. --dry-run prints plan to stderr
plan=$(MOCK_OP_FAIL=0 "$SCRIPT" --dry-run "$d" 2>&1)
if [[ "$plan" == *"DRY-RUN"* && "$plan" == *"fake-test-bucket"* ]]; then
  pass "37 --dry-run prints plan with bucket info"
else
  fail "37 --dry-run plan" "stderr did not contain expected markers"
fi
rm -rf "$d"

# ============================================================================
# Summary
# ============================================================================
total=$((PASS+FAIL))
printf '\n'
printf '================================================================\n'
printf '  Phase 4 upload.sh — %d/%d passed\n' "$PASS" "$total"
printf '================================================================\n'
if [[ "$FAIL" -gt 0 ]]; then
  printf '  FAILED:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
