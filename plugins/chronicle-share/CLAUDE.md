# chronicle-share Plugin

> Producer-side session chronicle sharing pipeline. Bundles Claude Code JSONL, sanitizes, uploads to Cloudflare R2, emits a 7-day presigned URL.

**Status:** Phases 0–9 complete (R2, bundle, sanitize, archive, upload, orchestrator, Telegram post, skills + doctor, marketplace registration, multi-project + date-range filtering). Plugin is feature-complete on the nasimubd fork; a consolidated upstream PR to terrylica/cc-skills remains the final step.

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
               chronicle-share.tar.gz with a sidecar .sha256.
                         │
                         ▼
4. Upload      aws s3 cp against the R2 endpoint (S3-compat API), then
               aws s3 presign --expires-in 604800 (7 days). Credentials
               loaded from 1Password.
                         │
                         ▼
5. Orchestrate share.sh wraps 1→6 into a single invocation and emits
               the presigned URL on stdout. Phase-specific exit codes
               (2/3/4/5/6) identify which step failed.
                         │
                         ▼
6. Post        post.sh shells out to Telethon (nasim profile) and sends
               a formatted message (URL + summary) into the Bruntwork
               Assignments & Deliverables topic.
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

## Phase 5 (orchestrator) — implemented

**Script:** [`scripts/share.sh`](./scripts/share.sh)
**Tests:** [`tests/test-share.sh`](./tests/test-share.sh)

### CLI surface
```
share.sh [--project PATH] [--limit N]                  (bundle args)
         [--expires-in SECONDS] [--key-prefix PATH]    (upload args)
         [--dry-run-upload]                             (safe mode)
         [--keep-staging]                               (debug)
```

Forwarded args:
- `--project`, `--limit` → `bundle.sh`
- `--expires-in`, `--key-prefix` → `upload.sh`
- `--dry-run-upload` → translates to `--dry-run` on `upload.sh` only (bundle/sanitize/archive still run for real)
- `--keep-staging` is consumed by `share.sh` itself, not forwarded

Stdout (on success): the 7-day presigned URL, single line, pipe-friendly for Phase 6 Telegram post. Stderr: progress logs from every phase plus one-line section headers.

Exit codes: `0` full pipeline success, `1` usage/validation, `2` bundle failed, `3` sanitize failed, `4` archive failed, `5` upload failed.

### Key behaviors
- **Sibling resolution** — `share.sh` locates `bundle.sh` / `sanitize.sh` / `archive.sh` / `upload.sh` via `$HERE` (its own directory), resolving symlinks first. Scripts work in-place from `plugins/chronicle-share/scripts/`.
- **Staging preservation on failure** — if any phase fails, the staging dir is left intact (regardless of `--keep-staging`) with a logged path so you can inspect what broke. Cleanup only happens on full success.
- **`--dry-run-upload` preserves staging** — because no real upload happened, there's nothing to produce and the staging is what you inspect.
- **Phase-specific exit codes** — `2/3/4/5` let callers distinguish which phase failed without parsing stderr.

### Test coverage
22-case suite at [`tests/test-share.sh`](./tests/test-share.sh), runnable standalone. Uses a PATH-independent shim strategy: copies `share.sh` into a temp dir next to fake `bundle.sh` / `sanitize.sh` / `archive.sh` / `upload.sh` scripts (each honoring `FAIL_BUNDLE` / `FAIL_SANITIZE` / `FAIL_ARCHIVE` / `FAIL_UPLOAD` env vars). No real 1Password creds or R2 access needed.

- **Usage + arg parsing (2)** — `--help`, unknown flag
- **Sibling validation (1)** — missing sibling script exits 1
- **Happy path (4)** — exits 0, stdout is URL, staging removed on success, `--keep-staging` preserves
- **`--dry-run-upload` (3)** — exits 0, no URL on stdout, staging preserved
- **Argument passthrough (5)** — `--project`+`--limit` reach bundle, STAGING reaches sanitize+archive, `--expires-in`+`--key-prefix` reach upload, `--dry-run-upload` translates to `--dry-run`, `--keep-staging` not forwarded
- **Per-phase failure (7)** — each phase failure → correct exit code (2/3/4/5) + staging preserved

All 22 pass as of 2026-04-21.

### Integration test (real R2)
Verified end-to-end 2026-04-21 against `nasim-chronicles`:
- `share.sh --project /Users/mdnasim/eon/cc-skills --limit 1 --key-prefix chronicles/test-phase5`
- Full pipeline ran in ~18 seconds (bundle → sanitize with 282 redactions → archive 1.60 MB → upload at ~16 MiB/s)
- Presigned URL on stdout → anonymous `curl` download returned HTTP 200 with byte-for-byte SHA-256 match (`5aba568a...`)
- Staging dir removed on success (per default behavior)
- R2 object cleaned up post-verification via `aws s3 rm`

## Phase 6 (post) — implemented

**Script:** [`scripts/post.sh`](./scripts/post.sh)
**Tests:** [`tests/test-post.sh`](./tests/test-post.sh)

### CLI surface
```
post.sh [--chat-id ID] [--topic-id N] [--dry-run] [--force] STAGING_DIR
```
- Positional `STAGING_DIR`: path with a manifest where `uploaded=true` (post-upload).
- `--chat-id`: default `-1003958083153` (Bruntwork supergroup). For testing, use `7730224133` = Nasim's own user ID → Saved Messages (zero-risk).
- `--topic-id`: default `2` (Assignments & Deliverables). Auto-ignored when the chat is a DM (positive chat_id).
- `--dry-run`: preview the exact message body on stderr; no send, no manifest mutation.
- `--force`: bypass the `posted=true` idempotency guard.

Stdout: the Telegram `message_id` (integer, single line). Stderr: progress logs. Exit codes: `0` sent, `1` usage/validation, `2` Telethon send failed, `3` manifest mutation failed.

### Key behaviors
- **Telethon via uv** — inline subprocess `uv run --python 3.13 --no-project --with telethon python3 <<'PYEOF'`. Session file: `~/.local/share/telethon/nasim.session`. API credentials: `TG_API_ID=32899228`, `TG_API_HASH` baked into the script. Requires pre-existing Telethon auth — fails fast if not signed in.
- **Forum-topic routing** — if `chat_id < 0` and `topic_id >= 1`, Telethon is invoked with `reply_to=<topic_id>` so the message lands in the correct forum thread. For DMs / non-forum chats, `reply_to` is omitted.
- **Pre-send validation** — requires `manifest.uploaded=true`, `upload.presigned_url`, `upload.expires_at_utc`, `archive.sha256`, `source.project_path` all present and non-null. Missing any → exit 1 before any Telegram call.
- **Idempotency guard** — refuses if `manifest.posted=true` already (unless `--force`).
- **Message body embedded in manifest** — the full message text is stored in `manifest.post.message_body` for audit.

### Message format (Telegram Markdown)
```
📦 *Session chronicle ready for review*

*Project:* `/Users/mdnasim/eon/cc-skills`
*Sessions:* N session(s), L line(s) (S raw)
*Redactions:* R
*Archive:* X MB (gzip) · SHA-256 `<first-12-hex>...`

[Download (7-day presigned URL)](https://...)

_Expires YYYY-MM-DDTHH:MM:SSZ. Generated by chronicle-share._
```

### Manifest v5 additions
Phase 6 flips `posted: true` and adds one new top-level object.

```jsonc
{
  // ... all Phase 1–4 fields unchanged ...
  "posted": true,                                 // was absent/false
  "post": {                                       // NEW
    "platform":      "telegram",
    "chat_id":       "-1003958083153",
    "topic_id":      2,
    "message_id":    347,
    "posted_at_utc": "2026-04-21T12:29:26Z",
    "message_body":  "📦 *Session chronicle ready for review*\n..."
  }
}
```

### Test coverage
31-case suite at [`tests/test-post.sh`](./tests/test-post.sh), runnable standalone. Uses a PATH shim for `uv` so tests never actually contact Telegram. Failure modes controllable via `MOCK_UV_FAIL`, `MOCK_TELETHON_FAIL`, `MOCK_NO_RESPONSE` env vars.

- **Usage + arg parsing (4)** — `--help`, missing `STAGING_DIR`, unknown flag, two positional
- **Validation guards (5)** — nonexistent staging, missing manifest, invalid JSON, `uploaded=false` refused, missing `presigned_url`
- **Happy path (11)** — exit 0, stdout is `message_id`, manifest has all 6 `post.*` keys, platform/chat_id/topic_id defaults, message body contains project path + URL + short SHA
- **Idempotency + `--force` (2)** — re-post refused, `--force` re-posts with new timestamp
- **Custom chat/topic (2)** — `--chat-id` / `--topic-id` honored
- **`--dry-run` (3)** — exits 0, manifest untouched, prints message preview on stderr
- **Telethon failure modes (4)** — uv subprocess fail → exit 2 + manifest unchanged, ok=false → exit 2, no response → exit 2

All 31 pass as of 2026-04-21.

### Integration test (real Telegram)
Two-step validation 2026-04-21:

1. **Smoke test** — `share.sh ... --post-chat-id 7730224133 --post-topic-id 1` posted to Nasim's Saved Messages. Verified message body format, cleaned up R2 object + message + staging.
2. **Real deliverable** — `share.sh --project ~/eon/cc-skills --limit 1` (all defaults) posted to Bruntwork supergroup topic 2 as message **347**. Verified via Telethon read-back: `reply_to.forum_topic=True` confirmed forum-topic routing worked; body rendered as expected (1 session, 5401 lines, 348 redactions, 1.63 MB archive). Object retained in R2 for Terry's review; presigned URL valid until 2026-04-28.

## Phase 5 orchestrator — Phase 6 chaining

`share.sh` was extended to chain Phase 6 after upload:

- `--no-post` — skip Phase 6 (stdout is just the presigned URL)
- `--post-chat-id ID` — forwarded to `post.sh`
- `--post-topic-id N` — forwarded to `post.sh`
- `--dry-run-upload` **implies `--no-post`** (dry-run has no real URL to share)
- New exit code `6` for Phase 6 failure (staging preserved for debug)

Tests extended to 29 cases (was 22) — added 7 Phase 6 orchestration checks (default invocation, `--no-post`, argpass, dry-run-implies-no-post, post failure → exit 6, staging preserved on post failure, stdout remains presigned URL).

## Phase 7 (skills) — implemented

**Files:**
- [`skills/share/SKILL.md`](./skills/share/SKILL.md) — full pipeline workflow skill
- [`skills/doctor/SKILL.md`](./skills/doctor/SKILL.md) — preflight diagnostic skill
- [`scripts/doctor.sh`](./scripts/doctor.sh) — backing script for the doctor skill (22-check preflight)

### Skill: share
Replaces the Phase 0 stub. YAML frontmatter exposes the skill to Claude Code via TRIGGERS ("share my chronicle", "share this session", "send chronicle to Terry", "post chronicle to Bruntwork", etc.). The body documents:

- **When to use** vs. Terry's `devops-tools:session-chronicle` consumer skill (clear scoping)
- **Prerequisites** linked to `/chronicle-share:doctor`
- **Default flow** — one-liner `share.sh --project $PWD --limit 1`
- **All 9 flags** with meaning + default + common scenarios
- **Error-code → phase → fix** matrix
- **Manifest v5** schema reference

Post-Phase-8, Claude Code auto-surfaces both skills via their SKILL.md frontmatter + TRIGGERS once the marketplace is subscribed. Direct script invocation still works for scripted / CI contexts:
```bash
~/.claude/plugins/marketplaces/cc-skills/plugins/chronicle-share/scripts/share.sh --project "$PWD" --limit 1
```

### Skill: doctor (new)
A `model: haiku` skill (fast, cheap) that runs `scripts/doctor.sh` and interprets the output. Checks cover:

| Category          | Check                                                 | Fatal?    |
| ----------------- | ----------------------------------------------------- | --------- |
| Shell tools       | `jq`, `shasum`, `tar`, `awk`, `find`, `date`          | Yes       |
| Package managers  | `uv`, `aws`, `op`                                     | Yes       |
| HTTP              | `curl`                                                | No (WARN) |
| 1Password         | Account `E37RVJRKWZAVFEXY6X2VA4PBWA` registered      | Yes       |
| 1Password         | Item `R2 Chronicle Share` — all 4 fields readable     | Yes       |
| Telethon          | `~/.local/share/telethon/nasim.session` present       | Yes       |
| Claude sessions   | Current `$PWD` has sessions                           | No (WARN) |
| Sanitizer         | Upstream `sanitize_sessions.py` locatable             | Yes       |
| Sibling scripts   | 6 pipeline scripts present + executable               | Yes       |
| R2 bucket         | `aws s3api head-bucket nasim-chronicles` succeeds    | Yes       |

Exit codes: `0` all pass, `1` warnings only, `2` at least one FAIL.

### `doctor.sh` CLI surface
```
doctor.sh [--quiet] [--json] [--help]
```
- `--quiet`: suppress per-check output; exit code still reflects overall status
- `--json`: emit the full report as a JSON array (machine-readable, overrides quiet)

Verified 2026-04-21 on Nasim's MacBook: 22/22 pass, JSON is valid, quiet mode respected.

### Fix-map embedded in the doctor skill
The skill body has a `common failures → fixes` table so Claude can automatically suggest the right remediation per check name (e.g. `op:account` FAIL → `op account add ...`; `sanitizer:upstream` FAIL → install `devops-tools` from the cc-skills marketplace).

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
- [x] **Phase 5** — `scripts/share.sh` (done 2026-04-21; now 29/29 tests pass; chains 1→6 including Phase 6 post; phase-specific exit codes 2/3/4/5/6)
- [x] **Phase 6** — `scripts/post.sh` (done 2026-04-21; 31/31 tests pass + real Bruntwork topic 2 post verified as msg 347; Telethon via uv; manifest v5)
- [x] **Phase 7** — `skills/share/SKILL.md` + `skills/doctor/SKILL.md` + `scripts/doctor.sh` (done 2026-04-21; stub replaced with 150-line functional skill; 22-check preflight verified 22/22 against live system)
- [x] **Phase 8** — marketplace registration (done 2026-04-22; `chronicle-share` entry appended to `.claude-plugin/marketplace.json` as the 32nd plugin on nasimubd fork, `devops` category, version `1.0.0`, 12 keywords; validator passes 32/32 registered, 203 skills; plugin.json bumped 0.0.1 → 1.0.0; next step is consolidated upstream PR to terrylica/cc-skills)
- [x] **Phase 9** — multi-project + date-range filtering (done 2026-04-22; bundle.sh gained `--since DATE`, `--until DATE`, `--all-projects`; share.sh passes them through; manifest gained `filters` block, per-session `project_path`/`project_encoded`, and source `mode`+`project_count`+`project_encodings` in all-projects mode; multi-project R2 key uses `all-projects` segment; all 129 downstream tests still pass; live verified with 21 sessions across 5 projects since 2026-04-16, 890 redactions, 10.42 MB archive)

## Boundary with upstream cc-skills

Per the memory rule set 2026-04-17: in this fork, Claude only adds new content authored by Nasim. Registration into upstream-owned registry files was deliberately deferred to Phase 8 (now done) — the marketplace entry is purely additive (new array element), not a modification of existing entries. Upstream (terrylica/cc-skills) remains untouched; see Terry's "brand-new plugin" policy in Bruntwork topic 6 — the plugin will land there via a single consolidated PR once Nasim signs off.

## References

- Upstream consumer-side skill: `plugins/devops-tools/skills/session-chronicle/SKILL.md`
- Upstream sanitizer: `plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py`
- Upstream S3 sharing ADR (opposite direction, for reference only): `docs/adr/2026-01-02-session-chronicle-s3-sharing.md`
- Telegram posting skill: `plugins/tlg/skills/send-media/SKILL.md`
