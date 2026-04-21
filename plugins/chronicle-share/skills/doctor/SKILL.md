---
name: doctor
description: "Preflight diagnostics for the chronicle-share pipeline. Checks tools (jq/shasum/tar/aws/op/uv), 1Password sign-in, R2 Chronicle Share item readability, Telethon session, Claude Code session dir, upstream sanitizer, sibling scripts, R2 bucket reachability. TRIGGERS - chronicle-share doctor, chronicle-share preflight, chronicle-share health, chronicle pipeline check, chronicle-share diagnose."
allowed-tools: Bash, Read
model: haiku
---

# chronicle:doctor

Run diagnostics across every external dependency the chronicle-share pipeline touches. Designed to be the first thing you run after cloning or when the pipeline suddenly stops working.

> **Self-Evolving Skill**: This skill improves through use. If instructions are wrong, parameters drifted, or a workaround was needed — fix this file immediately, don't defer. Only update for real, reproducible issues.

## When to use

- Before the first `/chronicle-share:share` run on a new machine
- When any phase of `share.sh` fails with a cryptic error
- When `op read` or `aws s3` commands unexpectedly fail
- When you want a one-shot confirmation that everything is green

## What it checks

| Category          | Check                                              | Fatal?  |
| ----------------- | -------------------------------------------------- | ------- |
| Shell tools       | `jq`, `shasum`, `tar`, `awk`, `find`, `date`       | Yes     |
| Package managers  | `uv`, `aws`, `op`                                  | Yes     |
| HTTP              | `curl`                                             | No (WARN) |
| 1Password         | Account `E37RVJRKWZAVFEXY6X2VA4PBWA` registered   | Yes     |
| 1Password         | Item `R2 Chronicle Share` — all 4 fields readable  | Yes     |
| Telethon          | `~/.local/share/telethon/nasim.session` present    | Yes     |
| Claude sessions   | `~/.claude/projects/<encoded-$PWD>/*.jsonl` exist  | No (WARN) |
| Sanitizer         | Upstream `sanitize_sessions.py` locatable          | Yes     |
| Sibling scripts   | bundle/sanitize/archive/upload/share/post executable | Yes   |
| R2 bucket         | `aws s3api head-bucket` on `nasim-chronicles` works | Yes    |

## Usage

From the plugin directory:

```bash
./plugins/chronicle-share/scripts/doctor.sh
```

From anywhere (marketplace install):

```bash
~/.claude/plugins/marketplaces/cc-skills/plugins/chronicle-share/scripts/doctor.sh
```

### Options

| Flag        | Effect                                                                     |
| ----------- | -------------------------------------------------------------------------- |
| `--quiet`   | Suppress per-check output; exit code still indicates overall status        |
| `--json`    | Emit the full report as a JSON array (machine-readable, overrides quiet)   |
| `--help`    | Show usage                                                                 |

### Exit codes

- `0` — all checks pass
- `1` — warnings only (pipeline works, but something is sub-optimal)
- `2` — at least one FAIL (pipeline will not work)

## Interpreting output

Each line is `[PASS] <check> <detail>`, `[WARN] <check> <detail>`, or `[FAIL] <check> <detail>`. The check name is a stable identifier (e.g. `tool:uv`, `op:item`, `r2:bucket`) — useful for grep / automation.

### Common failures → fixes

| Check               | Fix                                                                       |
| ------------------- | ------------------------------------------------------------------------- |
| `tool:*` FAIL       | `brew install <tool>`                                                     |
| `op:account` FAIL   | `op account add` (one-time); then `op signin --account=E37RVJRKWZAVFEXY6X2VA4PBWA` |
| `op:item:*` FAIL    | `op signin --account=E37RVJRKWZAVFEXY6X2VA4PBWA`                           |
| `telethon:session` FAIL | Authenticate Telethon: `tlg:setup` or manual flow                     |
| `sanitizer:upstream` FAIL | Install `devops-tools` from `cc-skills` marketplace                |
| `script:*` FAIL     | Re-clone or `git checkout plugins/chronicle-share/scripts/`               |
| `r2:bucket` FAIL    | Verify token in Cloudflare dashboard (scope = `nasim-chronicles`)         |
| `sessions:current` WARN | Run from a project with Claude Code history, or use `--project PATH`  |

## Workflow (Claude invocation)

When the user says *"check chronicle-share"* or an equivalent trigger:

1. Run `doctor.sh` (plain output).
2. If exit code is 0: tell the user everything is green, remind them they can run `/chronicle-share:share` anytime.
3. If exit code is 1: summarize the WARN items and whether they're likely to matter for the next action the user wants to take.
4. If exit code is 2: list each FAIL with the corresponding fix from the table above. If a fix requires an interactive command (like `op signin`), explain that the user needs to type it — do not run it unattended.

## Plugin docs

[Plugin CLAUDE.md](../../CLAUDE.md) — architecture, roadmap, per-phase implementation details.
