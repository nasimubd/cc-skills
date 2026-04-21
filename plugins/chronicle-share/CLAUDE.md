# chronicle-share Plugin

> Producer-side session chronicle sharing pipeline. Bundles Claude Code JSONL, sanitizes, uploads to Cloudflare R2, emits a 7-day presigned URL.

**Status:** Phases 0 (R2 provisioning), 1 (bundle), 2 (sanitize), 3 (archive), 4 (upload) complete. Phases 5–8 pending.

**Hub**: [Root CLAUDE.md](../../CLAUDE.md)

## Why this exists

Terry (supervisor) needs a reliable way to receive my session chronicles for review. Manual zip-and-upload is too slow; automated pipeline was requested in Bruntwork Assignments topic on 2026-04-16. The existing `devops-tools:session-chronicle` skill ships chronicles into `s3://eonlabs-findings` (Terry's bucket, credentials in shared 1Password vault); I have read access there but not write. This plugin is my own producer-side pipeline into R2.

## Target architecture

```
1. Bundle      scripts/bundle.sh enumerates ~/.claude/projects/<encoded-cwd>/
               JSONL files into a staging dir + manifest.json.
                         │
                         ▼
2. Sanitize    Shell out to the upstream sanitizer:
               ~/.claude/plugins/marketplaces/cc-skills/plugins/devops-tools/
                 skills/session-chronicle/scripts/sanitize_sessions.py
               — never skipped, never re-implemented locally.
                         │
                         ▼
3. Archive     tar+gzip the sanitized sessions + manifest into a single
               .tar.gz with a sidecar .sha256.
                         │
                         ▼
4. Upload      aws s3 cp against the R2 endpoint (S3-compat API).
               Credentials loaded from 1Password.
                         │
                         ▼
5. Presign     aws s3 presign --expires-in 604800 (7 days).
                         │
                         ▼
6. Emit        Print the URL to stdout. Optionally inline Telethon post
               into Bruntwork Assignments topic (nasim profile).
```

## Phase 1 (bundle) — implemented

**Script:** [`scripts/bundle.sh`](./scripts/bundle.sh)

### CLI surface
```
bundle.sh [--project PATH] [--out DIR] [--limit N]
```
- `--project`: project dir whose sessions to bundle (default: `$PWD`). Encoded per Claude Code's scheme (strip leading `/`, replace `/` and `.` with `-`, prepend `-`).
- `--out`: staging dir to create (default: `$TMPDIR/chronicle-share-<UTC>`). Must not exist (fail-safe).
- `--limit N`: bundle only the N newest sessions by mtime. `0` = all.

Stdout: the staging dir path. Stderr: all logs. Exit codes: `0` ok, `1` usage error, `2` no sessions.

### Staging layout
```
<OUT_DIR>/
├── manifest.json
└── sessions/
    └── <session-uuid>.jsonl   (one per session, newest first)
```

### Manifest schema (v1)
Downstream phases mutate this file in place. Single evolving record.

```jsonc
{
  "manifest_version": 1,
  "generated_at_utc": "2026-04-21T00:00:00Z",
  "generated_by": "chronicle-share/bundle.sh",
  "source": {
    "project_path":    "/Users/mdnasim/eon/cc-skills",
    "project_encoded": "-Users-mdnasim-eon-cc-skills",
    "host":            "MDs-MacBook-Pro",
    "claude_user":     "mdnasim"
  },
  "sessions": [
    {
      "session_id":  "<uuid>",
      "filename":    "<uuid>.jsonl",
      "size_bytes":  2570551,
      "line_count":  1793,
      "mtime_utc":   "2026-04-20T23:30:36Z",
      "sha256":      "b41fef...abf99"
    }
  ],
  "totals": {
    "session_count":    9,
    "total_size_bytes": 11532055
  },
  "sanitized": false,   // Phase 2 flips to true + adds redactions metadata
  "archived":  false    // Phase 3 flips to true + adds archive_path + archive_sha256
}
```

### Test coverage
15-case suite covers: `--help`, happy path, manifest shape, file count agreement, SHA-256 round-trip, `--limit 1` picks newest, explicit `--project`, nonexistent project (exit 1), missing session dir (exit 2), `--out` collision refused, `--limit 3` ordering, `--limit` clamping, `--limit 0 = all`, negative `--limit` rejected, unknown flag rejected. All pass as of 2026-04-21.

## Phase 2 (sanitize) — implemented

**Script:** [`scripts/sanitize.sh`](./scripts/sanitize.sh)

### CLI surface
```
sanitize.sh [--sanitizer PATH] STAGING_DIR
```
- Positional `STAGING_DIR`: the path returned by `bundle.sh` on stdout.
- `--sanitizer PATH`: override the auto-discovered upstream sanitizer. Auto-search order:
  1. `~/.claude/plugins/marketplaces/cc-skills/plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py` (installed marketplace)
  2. `~/eon/cc-skills/plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py` (dev mirror)

Stdout: same `STAGING_DIR` (for chaining). Stderr: logs. Exit codes: `0` ok, `1` usage/validation, `2` sanitizer invocation failure.

### Key behaviors
- **Never re-implements redaction logic** — shells out to Terry's upstream `sanitize_sessions.py`; its SHA-256 is recorded in the manifest so consumers can detect script drift.
- **Idempotency guard** — refuses to run if `manifest.sanitized` is already `true`. Bundle a fresh staging dir to re-sanitize.
- **Non-destructive** — keeps raw `sessions/` intact; sanitized output goes to a **new** `sessions-sanitized/` sibling.
- **Output count check** — fails (exit 2) if the sanitizer's output file count diverges from the manifest's session count.
- **Dependency check** — fails fast if `uv`, `jq`, or `shasum` is missing.

### Post-Phase-2 staging layout
```
<STAGING>/
├── manifest.json              (mutated: sanitized=true + new fields)
├── sessions/                   (unchanged — forensic audit trail)
├── sessions-sanitized/         (new — redacted JSONL, Phase 3 will archive this)
└── redaction_report.txt        (new — human-readable report)
```

### Manifest v2 additions
Phase 2 flips `sanitized: true` and adds two new top-level objects plus three fields per session.

```jsonc
{
  // ... all Phase 1 fields unchanged ...
  "sanitized": true,                                        // was false
  "sessions": [
    {
      // ... all Phase 1 session fields unchanged ...
      "sanitized_size_bytes": 2103987,                      // NEW
      "sanitized_line_count": 1793,                         // NEW
      "sanitized_sha256":     "a0b1c2...deadbeef"           // NEW
    }
  ],
  "sanitization": {                                         // NEW
    "sanitized_at_utc": "2026-04-21T00:46:12Z",
    "sanitizer_path":   "/Users/mdnasim/.claude/plugins/marketplaces/cc-skills/plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py",
    "sanitizer_sha256": "f6eda9be...06ff5c",                // fingerprint of the script used
    "report_path":      "<STAGING>/redaction_report.txt"
  },
  "redactions": {                                           // NEW
    "total": 272,
    "by_pattern": {
      "email_address":        110,
      "onepassword_item_id":   52,
      "onepassword_op_url":    48,
      "aws_access_key":        18,
      "tailscale_cgnat_ip":    17
      // ... other patterns that had non-zero counts ...
    }
  }
}
```

### Test coverage
14-case suite covers: `--help`, missing staging dir (exit 1), staging without manifest (exit 1), staging without sessions/ (exit 1), missing `STAGING_DIR` arg, happy path end-to-end, post-sanitize manifest schema, file count parity raw↔sanitized, sanitized SHA-256 round-trip + valid JSONL, idempotency guard (re-sanitize refused), **canary with 4 known secrets** (email / GitHub PAT / AWS key / JWT — all replaced with correct placeholders), bad `--sanitizer` path rejected, unknown flag rejected, two positional args rejected. All pass as of 2026-04-21.

## Phase 3 (archive) — implemented

**Script:** [`scripts/archive.sh`](./scripts/archive.sh)
**Tests:** [`tests/test-archive.sh`](./tests/test-archive.sh)

### CLI surface
```
archive.sh [--force] STAGING_DIR
```
- Positional `STAGING_DIR`: the path returned by `sanitize.sh` on stdout (must have `manifest.sanitized=true`).
- `--force`: bypass the idempotency guard and re-create the archive.

Stdout: the same `STAGING_DIR` (for chaining). Stderr: logs. Exit codes: `0` ok, `1` usage/validation, `2` archive creation failed.

### Key behaviors
- **Fixed-name artifact** — always `chronicle-share.tar.gz` inside `STAGING_DIR`. Phase 4 (upload) knows exactly where to find it; no discovery needed.
- **Sidecar SHA-256** — `chronicle-share.tar.gz.sha256` written alongside in `shasum -c`-compatible format (`<sha>  <filename>`).
- **Raw `sessions/` excluded** — only `sessions-sanitized/`, `manifest.json`, and `redaction_report.txt` go into the archive. Pre-sanitization data stays local for forensic audit.
- **Embedded manifest snapshot** — the archive carries `manifest.json` with `archived=true` and the `archive` subfield populated (filename/format/created_at_utc/contents) but **without** `size_bytes`/`sha256` (those are self-referential). Consumers extracting the archive get full provenance.
- **Outer manifest is superset** — the manifest left in `STAGING_DIR` after Phase 3 is the embedded manifest plus `archive.size_bytes` and `archive.sha256`. That's what Phase 4 reads for upload metadata.
- **Idempotency guard** — refuses if `manifest.archived` is already `true` unless `--force` is passed.

### Post-Phase-3 staging layout
```
<STAGING>/
├── manifest.json                    (mutated: archived=true + archive.*)
├── chronicle-share.tar.gz            (Phase 4 upload artifact)
├── chronicle-share.tar.gz.sha256     (sidecar for verification)
├── sessions/                         (unchanged — forensic audit)
├── sessions-sanitized/               (unchanged on disk, packaged in archive)
└── redaction_report.txt              (unchanged on disk, packaged in archive)
```

### Manifest v3 additions
Phase 3 flips `archived: true` and adds one new top-level object.

```jsonc
{
  // ... all Phase 1 + Phase 2 fields unchanged ...
  "archived": true,                                      // was false
  "archive": {                                           // NEW
    "filename":       "chronicle-share.tar.gz",
    "format":         "tar.gz",
    "created_at_utc": "2026-04-21T11:26:08Z",
    "contents": [
      "manifest.json",
      "sessions-sanitized/*.jsonl",
      "redaction_report.txt"
    ],
    "size_bytes":     1394330,                           // outer only (self-referential in inner)
    "sha256":         "9f89ba19...4fb4f96"               // outer only
  }
}
```

### Test coverage
32-case suite at [`tests/test-archive.sh`](./tests/test-archive.sh), runnable standalone (no Phase 1/2 required — mocks a post-sanitize staging dir). Covers:

- **Usage + arg parsing (4)** — `--help`, missing `STAGING_DIR`, unknown flag, two positional args
- **Validation guards (8)** — nonexistent staging, missing/invalid manifest, `sanitized=false` refused, missing `sessions-sanitized/` or report, empty `sessions-sanitized/`, manifest/file count mismatch
- **Happy path (3)** — exit 0, stdout echoes staging, artifact + sidecar written
- **Outer manifest (6)** — `archived=true`, all 6 `archive.*` keys, filename/format, `size_bytes` matches `stat`, `sha256` matches `shasum`
- **Sidecar (2)** — exact line format, `shasum -c` passes
- **Archive contents (3)** — valid `tar.gz`, contains all 3 expected entries, raw `sessions/` excluded
- **Embedded manifest (3)** — `archived=true`, has 4 `archive.*` keys (no self-referential size/sha), sanitized JSONL round-trips byte-for-byte
- **Idempotency + `--force` (3)** — re-archive refused, `--force` succeeds, sidecar still verifies post-force

All 32 pass as of 2026-04-21. Verified end-to-end against a real 5.95 MB session: compresses to 1.39 MB (76% ratio), sidecar verifies, archive is a valid tar.gz extractable by `tar -xzf`.

## Phase 4 (upload) — implemented

**Script:** [`scripts/upload.sh`](./scripts/upload.sh)
**Tests:** [`tests/test-upload.sh`](./tests/test-upload.sh)

### CLI surface
```
upload.sh [--dry-run] [--expires-in SECONDS] [--key-prefix PATH] [--force] STAGING_DIR
```
- Positional `STAGING_DIR`: the path returned by `archive.sh` (must have `manifest.archived=true`).
- `--dry-run`: validate + load creds + print the plan; **does not** upload or mutate manifest.
- `--expires-in SECONDS`: presigned URL TTL. Default `604800` (7 days). Max `604800` — enforced before hitting aws CLI.
- `--key-prefix PATH`: override the default `chronicles` prefix (useful for scratch / testing).
- `--force`: bypass the `uploaded=true` idempotency guard.

Stdout: the presigned URL (single line), so Phase 5 orchestrator + Phase 6 Telegram post can consume it via `$(upload.sh ...)`. Stderr: all logs. Exit codes: `0` ok, `1` usage/validation, `2` 1Password credential fetch failed, `3` R2 upload or presign failed.

### Key behaviors
- **Credentials load from 1Password only** — item `R2 Chronicle Share` in the Personal vault, account `E37RVJRKWZAVFEXY6X2VA4PBWA`. Fetched via 4 `op read` calls into shell-local variables, never exported, never logged, never written to disk.
- **Env-var injection into aws** — `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_DEFAULT_REGION=auto` are set inline per-invocation; `--endpoint-url` is always passed. The aws CLI sees them only for that one command.
- **Archive integrity verified pre-upload** — `shasum -a 256 -c chronicle-share.tar.gz.sha256` must pass; a tampered tarball is refused before a single byte is uploaded.
- **Deterministic object key** — `<prefix>/<project_encoded>/<ts>-<short_sha>.tar.gz`, where `ts` is `archive.created_at_utc` with `:` replaced by `-` (URL-safe) and `short_sha` is the first 8 hex chars of `archive.sha256`. Re-running without `--force` refuses; re-running with `--force` overwrites the same key with a fresh presigned URL.
- **Idempotency guard** — refuses if `manifest.uploaded` is already `true` unless `--force` is passed.

### Object key scheme
```
<prefix>/<project_encoded>/<ts>-<short_sha>.tar.gz

Example:
chronicles/-Users-mdnasim-eon-cc-skills/2026-04-21T11-56-41Z-a628aef3.tar.gz
```

### Manifest v4 additions
Phase 4 flips `uploaded: true` and adds one new top-level object.

```jsonc
{
  // ... all Phase 1 + 2 + 3 fields unchanged ...
  "uploaded": true,                                      // was absent/false
  "upload": {                                            // NEW
    "bucket":              "nasim-chronicles",
    "key":                 "chronicles/-Users-.../2026-04-21T11-56-41Z-a628aef3.tar.gz",
    "endpoint_url":        "https://f0894f5d...r2.cloudflarestorage.com",
    "uploaded_at_utc":     "2026-04-21T11:57:01Z",
    "presigned_url":       "https://...?X-Amz-Algorithm=AWS4-HMAC-SHA256&...",
    "expires_in_seconds":  604800,
    "expires_at_utc":      "2026-04-28T11:57:01Z"
  }
}
```

### Test coverage
37-case suite at [`tests/test-upload.sh`](./tests/test-upload.sh), runnable standalone. Ships a PATH shim for `op` and `aws` so no real credentials or network access are required. Shim failure modes are controlled via env vars (`MOCK_OP_FAIL=1`, `MOCK_AWS_CP_FAIL=1`, `MOCK_AWS_PRESIGN_FAIL=1`).

- **Usage + arg parsing (7)** — `--help`, missing `STAGING_DIR`, unknown flag, two positional, `--expires-in` non-numeric/zero/>604800
- **Validation guards (8)** — nonexistent staging, missing/invalid manifest, `archived=false` refused, missing archive/sidecar, corrupt archive (sidecar mismatch), missing `archive.sha256`
- **Credential load (1)** — op failure exits 2
- **Happy path (9)** — exit 0, stdout is presigned URL, manifest has all 7 `upload.*` keys, bucket/key shape/TTL correct, URL matches stdout, `expires_at_utc` = `uploaded_at_utc + 604800`
- **Idempotency + `--force` (2)** — re-upload refused, `--force` re-uploads with new timestamp
- **Flag behavior (2)** — `--expires-in 3600` honored, `--key-prefix` honored
- **AWS failure modes (3)** — `cp` fails → exit 3 + manifest unchanged, `presign` fails → exit 3
- **`--dry-run` (5)** — exits 0, manifest unchanged, no `upload` subfield, still validates creds, prints plan

All 37 pass as of 2026-04-21.

### Integration test (real R2)
Verified end-to-end 2026-04-21 against the live `nasim-chronicles` bucket:
- 1 real Claude Code session (5.95 MB raw) → sanitized → archived (1.50 MB tar.gz after 261 redactions) → uploaded to R2 at ~16 MiB/s
- Presigned URL (7-day TTL) downloaded anonymously via `curl` → HTTP 200
- Downloaded bytes match `archive.sha256` exactly (byte-for-byte round-trip confirmed)
- Test object cleaned up post-verification via `aws s3 rm`; follow-up curl to the same presigned URL returns HTTP 404 (confirms deletion)

## Key design decisions (to be formalized)

| Decision | Choice | Rationale |
| --- | --- | --- |
| Storage | Cloudflare R2 | Free tier (10 GB), no egress fees, S3-compat API. Confirmed by Terry as recommended. |
| Sanitizer | Shell out to upstream | Single source of truth; never drifts when Terry updates the patterns. |
| Compression | gzip (tar.gz) | Cross-platform, no new deps. Phase 3 can extend to zstd later without breaking the contract (archive format lives in `manifest.archive.format`). |
| URL format | Presigned, 7-day expiry | Matches Terry's own pipeline's `X-Amz-Expires=604800`. |
| Credentials | 1Password (separate item from Terry's) | Isolation: my R2 creds are mine, not the company's. |
| Telegram post | Delegated to `tlg:send-media` | Uses existing Telethon personal-account session; no new bot infra. |

## Roadmap

- [x] **Phase 0** — R2 account + bucket + API token + 1Password item (done 2026-04-21; verified via end-to-end presigned-URL download)
- [x] **Phase 1** — `scripts/bundle.sh` (done 2026-04-21; 15/15 tests pass)
- [x] **Phase 2** — `scripts/sanitize.sh` (done 2026-04-21; 14/14 tests pass including canary with 4 real-format secrets)
- [x] **Phase 3** — `scripts/archive.sh` (done 2026-04-21; 32/32 tests pass + E2E verified; tar.gz + sidecar SHA; manifest v3)
- [x] **Phase 4** — `scripts/upload.sh` (done 2026-04-21; 37/37 tests pass + real R2 upload verified end-to-end; manifest v4; 1Password-backed creds; 7-day presigned URL)
- [ ] **Phase 5** — `scripts/share.sh` (orchestrator chaining 1→4; first working end-to-end)
- [ ] **Phase 6** — inline Telethon post (nasim profile → Bruntwork topic 2)
- [ ] **Phase 7** — full `skills/share/SKILL.md` workflow + `skills/doctor/SKILL.md` preflight
- [ ] **Phase 8** — discoverability: user-global `~/.claude/commands/chronicle-share.md` OR marketplace.json registration (requires Nasim's explicit sign-off per fork rule)

## Boundary with upstream cc-skills

Per the memory rule set 2026-04-17: in this fork, Claude only adds new content authored by Nasim. Registration into upstream-owned registry files (`.claude-plugin/marketplace.json`, `.mise.toml`) is intentionally **not** done in the scaffolding commit — to be addressed as a separate, explicit step.

## References

- Upstream consumer-side skill: `plugins/devops-tools/skills/session-chronicle/SKILL.md`
- Upstream sanitizer: `plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py`
- Upstream S3 sharing ADR (opposite direction, for reference only): `docs/adr/2026-01-02-session-chronicle-s3-sharing.md`
- Telegram posting skill: `plugins/tlg/skills/send-media/SKILL.md`
