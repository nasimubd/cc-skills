---
name: share
description: "Bundle + sanitize + archive + upload Claude Code session JSONL to Cloudflare R2, emit a 7-day presigned URL, and post to Bruntwork Assignments topic. TRIGGERS - share my chronicle, share this session, upload chronicle, send chronicle to Terry, post chronicle to Bruntwork, chronicle-share run."
allowed-tools: Bash, Read, AskUserQuestion
---

# chronicle:share

Producer-side pipeline that packages the current project's Claude Code sessions into a sanitized, R2-hosted archive, then posts the 7-day presigned URL to Telegram.

> **Self-Evolving Skill**: This skill improves through use. If instructions are wrong, parameters drifted, or a workaround was needed — fix this file immediately, don't defer. Only update for real, reproducible issues.

## When to use

- User asks to share a session, chronicle, or transcript with their supervisor / peers
- User wants to upload a Claude Code session to Cloudflare R2
- User asks for a 7-day presigned URL to a session bundle

**Scope:** this plugin is a *producer* into Nasim's own `nasim-chronicles` R2 bucket. It is NOT the same as `devops-tools:session-chronicle` (Terry's consumer-side skill pointing at `eonlabs-findings`).

## Prerequisites

Run `/chronicle-share:doctor` first if you're unsure. Required:

- `op` (1Password CLI) signed into account `E37RVJRKWZAVFEXY6X2VA4PBWA`. Item `R2 Chronicle Share` in Personal vault must be readable.
- `aws` CLI v2 installed (R2 S3-compat endpoint).
- `uv` installed (upstream sanitizer runs via `uv run`; Telethon post also runs via `uv run`).
- `jq`, `shasum`, `tar`, `awk` on PATH.
- Telethon session: `~/.local/share/telethon/nasim.session` present.
- Upstream sanitizer: `~/.claude/plugins/marketplaces/cc-skills/plugins/devops-tools/skills/session-chronicle/scripts/sanitize_sessions.py` (or `~/eon/cc-skills/...` dev mirror).

If any of these are missing, stop and invoke `/chronicle-share:doctor` to get a detailed remediation matrix.

## Default flow

```bash
# From the project directory whose sessions you want to share (default: $PWD)
~/.claude/plugins/marketplaces/cc-skills/plugins/chronicle-share/scripts/share.sh \
  --project "$PWD" \
  --limit 1
```

Or, when running from the plugin checkout directly:

```bash
./plugins/chronicle-share/scripts/share.sh --project "$PWD" --limit 1
```

Default behavior:

- Bundle the 1 newest session JSONL from `~/.claude/projects/<encoded-cwd>/`
- Sanitize via upstream `sanitize_sessions.py` (secrets redacted)
- Archive into `chronicle-share.tar.gz` with sidecar `.sha256`
- Upload to `s3://nasim-chronicles/chronicles/<project_encoded>/<ts>-<short_sha>.tar.gz`
- Generate a 7-day presigned URL
- Post formatted message to Bruntwork supergroup `-1003958083153` forum topic **2 "Assignments & Deliverables"**
- Clean up the local staging dir

Stdout (single line): the presigned URL. Stderr: step-by-step progress.

## Options

| Flag                   | Default           | Meaning                                                                 |
| ---------------------- | ----------------- | ----------------------------------------------------------------------- |
| `--project PATH`       | `$PWD`            | Project whose sessions to share                                         |
| `--limit N`            | all sessions      | Only bundle the N newest by mtime (`0` = all)                           |
| `--expires-in SECONDS` | `604800` (7d)     | Presigned URL TTL (max 604800, R2 cap)                                  |
| `--key-prefix PATH`    | `chronicles`      | R2 object key prefix                                                    |
| `--post-chat-id ID`    | `-1003958083153`  | Telegram chat (use `7730224133` for your own Saved Messages)            |
| `--post-topic-id N`    | `2`               | Forum topic (auto-ignored for non-forum chats)                          |
| `--no-post`            | (off)             | Skip Phase 6; just emit the presigned URL                               |
| `--dry-run-upload`     | (off)             | Run bundle/sanitize/archive for real, dry-run the upload (implies `--no-post`) |
| `--keep-staging`       | (off)             | Preserve the temp staging dir after success (for debugging)             |

## Scenarios

### Default — share the current session

```bash
./plugins/chronicle-share/scripts/share.sh --project "$PWD" --limit 1
```

### Send to Saved Messages (private, for testing)

```bash
./plugins/chronicle-share/scripts/share.sh \
  --project "$PWD" --limit 1 \
  --post-chat-id 7730224133 --post-topic-id 1
```

### Upload without posting (get URL only)

```bash
./plugins/chronicle-share/scripts/share.sh --project "$PWD" --limit 1 --no-post
```

### Shorter URL expiry (1 hour)

```bash
./plugins/chronicle-share/scripts/share.sh --project "$PWD" --limit 1 --expires-in 3600
```

### Dry-run the whole pipeline (no R2 write, no Telegram)

```bash
./plugins/chronicle-share/scripts/share.sh --project "$PWD" --limit 1 --dry-run-upload
```

## Error handling

Exit codes identify the failing phase:

| Exit | Phase       | Typical cause                                           | Fix                                           |
| ---- | ----------- | ------------------------------------------------------- | --------------------------------------------- |
| `1`  | usage       | Bad flag, missing required tool                         | Fix the invocation                            |
| `2`  | bundle      | No session dir for `$PWD`                               | Run from a project with Claude Code history  |
| `3`  | sanitize    | Upstream sanitizer missing or uv issue                  | `/chronicle-share:doctor`                     |
| `4`  | archive     | Disk / tar failure                                      | Check disk space                              |
| `5`  | upload      | R2 credentials or bucket issue                          | `op signin --account=E37RVJRKWZAVFEXY6X2VA4PBWA`  |
| `6`  | post        | Telethon session expired or chat inaccessible           | Re-auth Telethon                              |

On any phase failure, the staging dir is preserved (path logged on stderr) for inspection. On success, staging is auto-removed unless `--keep-staging` is set.

## Manifest

Each run evolves a single `manifest.json` through phases 1-6. After a full successful run, the manifest contains (among other fields):

- `manifest_version`, `generated_at_utc`, `generated_by`, `source.*`
- `sessions[]` with per-session SHA-256 (raw + sanitized), size, line count
- `sanitized: true`, `sanitization.*` (sanitizer SHA fingerprint, report path)
- `redactions.total` + `redactions.by_pattern`
- `archived: true`, `archive.*` (filename, format, created_at_utc, size, SHA)
- `uploaded: true`, `upload.*` (bucket, key, endpoint, presigned_url, expires_at_utc)
- `posted: true`, `post.*` (platform, chat_id, topic_id, message_id, posted_at_utc, message_body)

See [Plugin CLAUDE.md](../../CLAUDE.md) for the full manifest v5 schema and per-phase behavior.

## Plugin docs

[Plugin CLAUDE.md](../../CLAUDE.md) — architecture, roadmap, boundary with upstream cc-skills, per-phase implementation details.
