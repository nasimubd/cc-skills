#!/usr/bin/env bash
# bundle.sh — Phase 1 of the chronicle-share pipeline.
#
# Enumerate Claude Code session JSONL files for a project, copy them into a
# staging directory, and write a manifest.json describing the bundle.
#
# The manifest is the single evolving record that downstream phases mutate:
#   Phase 2 (sanitize) flips `sanitized: false -> true` and adds redaction metadata.
#   Phase 3 (archive)  flips `archived: false  -> true` and adds archive metadata.
#   Phase 4 (upload)   adds presigned URL + object key.
#
# Usage:
#   bundle.sh [--project PATH] [--out DIR] [--limit N]
#   bundle.sh --help
#
# Stdout: staging directory path (one line) on success.
# Stderr: all human-readable logs and errors.
#
# Exit codes:
#   0  bundle created
#   1  usage or validation error
#   2  no sessions found for the requested project

set -euo pipefail

# --- defaults ---------------------------------------------------------------
PROJECT=""
PROJECT_SET=0           # track whether --project was explicitly passed
OUT_DIR=""
LIMIT=0                 # 0 = no limit
SINCE=""                # mtime lower bound (passed to find -newermt)
UNTIL=""                # mtime upper bound (exclusive, via ! -newermt)
ALL_PROJECTS=0

# --- helpers ----------------------------------------------------------------
log() { printf '[bundle] %s\n' "$*" >&2; }
err() { printf '[bundle] ERROR: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: bundle.sh [OPTIONS]

Enumerate Claude Code session JSONL files for a project and stage them for
the rest of the chronicle-share pipeline.

Options:
  --project PATH    Single project whose sessions to bundle (default: $PWD).
                    Encoded via Claude Code's scheme: strip leading '/',
                    replace '/' and '.' with '-', prepend '-'.
                    Mutually exclusive with --all-projects.
  --all-projects    Scan every directory under ~/.claude/projects/ instead of
                    a single project. Each session entry is tagged with its
                    project_path and project_encoded. Combine with --since /
                    --until to narrow by date.
  --since DATE      Only include sessions with mtime >= DATE (inclusive).
                    Accepts anything 'find -newermt' accepts: YYYY-MM-DD,
                    'YYYY-MM-DD HH:MM', ISO-8601, relative forms, etc.
  --until DATE      Only include sessions with mtime < DATE (exclusive).
  --out DIR         Staging directory to create. Must not exist yet.
                    Default: $TMPDIR/chronicle-share-<UTC-timestamp>
  --limit N         Bundle only the N newest sessions (by mtime) across the
                    selected project(s). 0 = all. Applied after --since/--until.
  --help, -h        Show this help.

Staging layout (flat — downstream sanitize/archive phases require maxdepth 1):
  <OUT_DIR>/
  ├── manifest.json
  └── sessions/
      └── <session-id>.jsonl

Per-session manifest entry fields (ALL modes):
  session_id, filename, size_bytes, line_count, mtime_utc, sha256,
  project_path, project_encoded

On success, the staging directory path is printed to stdout; logs go to stderr.
EOF
}

# --- arg parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)      PROJECT="${2:?--project requires a path}"; PROJECT_SET=1; shift 2 ;;
    --all-projects) ALL_PROJECTS=1; shift ;;
    --since)        SINCE="${2:?--since requires a date}";    shift 2 ;;
    --until)        UNTIL="${2:?--until requires a date}";    shift 2 ;;
    --out)          OUT_DIR="${2:?--out requires a path}";    shift 2 ;;
    --limit)        LIMIT="${2:?--limit requires a number}";  shift 2 ;;
    --help|-h)      usage; exit 0 ;;
    *) err "unknown arg: $1"; usage >&2; exit 1 ;;
  esac
done

# --- validate ---------------------------------------------------------------
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  err "--limit must be a non-negative integer (got: $LIMIT)"
  exit 1
fi

if [[ "$ALL_PROJECTS" -eq 1 && "$PROJECT_SET" -eq 1 ]]; then
  err "--project and --all-projects are mutually exclusive"
  exit 1
fi

for bin in jq shasum stat find; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    err "required tool not on PATH: $bin"
    exit 1
  fi
done

# Build list of (project_encoded, session_dir) pairs to scan.
declare -a scan_encoded=()
declare -a scan_dirs=()

if [[ "$ALL_PROJECTS" -eq 1 ]]; then
  base="$HOME/.claude/projects"
  if [[ ! -d "$base" ]]; then
    err "$base does not exist — no Claude Code projects to scan"
    exit 2
  fi
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    enc="$(basename "$d")"
    # Skip empty dirs (no .jsonl at all — saves a round of find).
    if ! compgen -G "$d"*.jsonl > /dev/null; then continue; fi
    scan_encoded+=("$enc")
    scan_dirs+=("${d%/}")
  done
  if [[ ${#scan_dirs[@]} -eq 0 ]]; then
    err "no Claude Code project directories with *.jsonl found under $base"
    exit 2
  fi
else
  # Single-project mode (default or explicit --project).
  if [[ -z "$PROJECT" ]]; then PROJECT="$PWD"; fi
  if [[ ! -d "$PROJECT" ]]; then
    err "project path is not a directory: $PROJECT"
    exit 1
  fi
  PROJECT="$(cd "$PROJECT" && pwd)"   # normalize to absolute
  encoded="-$(printf '%s' "$PROJECT" | sed 's|^/||' | tr '/.' '--')"
  session_dir="$HOME/.claude/projects/$encoded"
  if [[ ! -d "$session_dir" ]]; then
    err "no Claude Code session directory for this project"
    err "  project : $PROJECT"
    err "  encoded : $encoded"
    err "  looked  : $session_dir"
    exit 2
  fi
  scan_encoded+=("$encoded")
  scan_dirs+=("$session_dir")
fi

if [[ -z "$OUT_DIR" ]]; then
  tmp="${TMPDIR:-/tmp}"
  OUT_DIR="${tmp%/}/chronicle-share-$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [[ -e "$OUT_DIR" ]]; then
  err "out dir already exists: $OUT_DIR"
  err "  refusing to overwrite; pick a different --out or remove it first"
  exit 1
fi

# --- enumerate sessions across all scan dirs (sorted newest-first) ----------
# Emit "<mtime>\t<encoded>\t<path>" tuples so we can sort globally then attribute
# each session back to its project.
tuples_tmp="$(mktemp)"
for ((i=0; i<${#scan_dirs[@]}; i++)); do
  d="${scan_dirs[$i]}"
  enc="${scan_encoded[$i]}"

  find_args=("$d" -maxdepth 1 -type f -name '*.jsonl')
  if [[ -n "$SINCE" ]]; then
    find_args+=(-newermt "$SINCE")
  fi
  if [[ -n "$UNTIL" ]]; then
    find_args+=(! -newermt "$UNTIL")
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    mt=$(stat -f %m "$path")
    printf '%s\t%s\t%s\n' "$mt" "$enc" "$path" >> "$tuples_tmp"
  done < <(find "${find_args[@]}")
done

# Sort by mtime DESC across everything, then apply --limit.
sorted_tuples="$(mktemp)"
sort -k1,1 -rn "$tuples_tmp" > "$sorted_tuples"
rm -f "$tuples_tmp"

found_total=$(wc -l < "$sorted_tuples" | awk '{print $1}')
if [[ "$found_total" -eq 0 ]]; then
  err "no *.jsonl sessions matched the filter"
  if [[ "$ALL_PROJECTS" -eq 1 ]]; then
    err "  mode   : all-projects (${#scan_dirs[@]} project dir(s) scanned)"
  else
    err "  project: $PROJECT"
    err "  encoded: ${scan_encoded[0]}"
  fi
  if [[ -n "$SINCE" ]]; then err "  since  : $SINCE"; fi
  if [[ -n "$UNTIL" ]]; then err "  until  : $UNTIL"; fi
  rm -f "$sorted_tuples"
  exit 2
fi

if [[ "$LIMIT" -gt 0 && "$LIMIT" -lt "$found_total" ]]; then
  head -n "$LIMIT" "$sorted_tuples" > "$sorted_tuples.trim"
  mv "$sorted_tuples.trim" "$sorted_tuples"
fi

bundle_total=$(wc -l < "$sorted_tuples" | awk '{print $1}')

if [[ "$ALL_PROJECTS" -eq 1 ]]; then
  log "mode     : all-projects (${#scan_dirs[@]} project dir(s) scanned)"
else
  log "project  : $PROJECT"
  log "encoded  : ${scan_encoded[0]}"
fi
if [[ -n "$SINCE" ]]; then log "since    : $SINCE"; fi
if [[ -n "$UNTIL" ]]; then log "until    : $UNTIL"; fi
log "found    : $found_total session(s); bundling $bundle_total"
log "out dir  : $OUT_DIR"

# --- stage files + build manifest entries -----------------------------------
mkdir -p "$OUT_DIR/sessions"

manifest_entries="$(mktemp)"
trap 'rm -f "$manifest_entries" "$sorted_tuples"' EXIT

# Collect unique encoded projects represented in the bundle (for source.*).
declare -a bundled_encoded=()

total_bytes=0
while IFS=$'\t' read -r mt_epoch proj_enc src; do
  [[ -n "$src" ]] || continue
  filename="$(basename "$src")"
  session_id="${filename%.jsonl}"
  dst="$OUT_DIR/sessions/$filename"

  # Guard against the astronomically unlikely cross-project UUID collision.
  if [[ -e "$dst" ]]; then
    err "cross-project session-id collision on $filename — aborting"
    exit 1
  fi

  cp "$src" "$dst"

  size_bytes=$(stat -f %z "$src")
  line_count=$(awk 'END{print NR}' "$src")
  mtime_utc=$(date -u -r "$mt_epoch" +%Y-%m-%dT%H:%M:%SZ)
  sha=$(shasum -a 256 "$src" | awk '{print $1}')

  # Best-effort recovery of the original project path from the first `cwd`
  # value embedded in the JSONL. Falls back to null if not present.
  proj_path=$(awk 'NR<=30' "$src" | jq -r 'select(.cwd) | .cwd' 2>/dev/null | head -1)
  if [[ -z "$proj_path" ]]; then proj_path="(unknown)"; fi

  total_bytes=$(( total_bytes + size_bytes ))

  # Track unique encoded projects (small N, O(N) scan fine).
  seen=0
  for e in ${bundled_encoded[@]+"${bundled_encoded[@]}"}; do
    [[ "$e" == "$proj_enc" ]] && { seen=1; break; }
  done
  [[ "$seen" -eq 0 ]] && bundled_encoded+=("$proj_enc")

  jq -nc \
    --arg sid   "$session_id" \
    --arg fn    "$filename" \
    --argjson sz "$size_bytes" \
    --argjson lc "$line_count" \
    --arg mt    "$mtime_utc" \
    --arg sh    "$sha" \
    --arg pp    "$proj_path" \
    --arg pe    "$proj_enc" \
    '{session_id:$sid, filename:$fn, size_bytes:$sz, line_count:$lc, mtime_utc:$mt, sha256:$sh, project_path:$pp, project_encoded:$pe}' \
    >> "$manifest_entries"
done < "$sorted_tuples"

# --- assemble manifest ------------------------------------------------------
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host_val="$(hostname -s 2>/dev/null || hostname)"
user_val="$(whoami)"

# Build source block depending on mode.
# project_path and project_encoded are populated in BOTH modes for downstream
# compatibility (upload.sh keys R2 objects by project_encoded; post.sh shows
# project_path in the Telegram body). In multi-project mode they become
# synthetic values that still act as valid R2 path segments.
if [[ "$ALL_PROJECTS" -eq 1 ]]; then
  encoded_json=$(printf '%s\n' "${bundled_encoded[@]}" | jq -R . | jq -sc .)
  source_block=$(jq -nc \
    --arg host "$host_val" \
    --arg user "$user_val" \
    --arg scan "$HOME/.claude/projects" \
    --argjson encs "$encoded_json" \
    '{
      mode:              "all-projects",
      project_path:      "(all projects)",
      project_encoded:   "all-projects",
      scan_base:         $scan,
      project_count:     ($encs | length),
      project_encodings: $encs,
      host:              $host,
      claude_user:       $user
    }')
else
  source_block=$(jq -nc \
    --arg proj "$PROJECT" \
    --arg enc  "${scan_encoded[0]}" \
    --arg host "$host_val" \
    --arg user "$user_val" \
    '{
      mode:            "single-project",
      project_path:    $proj,
      project_encoded: $enc,
      host:            $host,
      claude_user:     $user
    }')
fi

# Build filters block (null out unused fields for cleanliness).
filters_block=$(jq -nc \
  --arg since "$SINCE" \
  --arg until "$UNTIL" \
  --argjson limit "$LIMIT" \
  --argjson all_projects $([[ "$ALL_PROJECTS" -eq 1 ]] && echo true || echo false) \
  '{since:(if $since=="" then null else $since end),
    until:(if $until=="" then null else $until end),
    limit: $limit,
    all_projects: $all_projects}')

jq -s \
  --arg gen_at "$now_utc" \
  --arg gen_by "chronicle-share/bundle.sh" \
  --argjson source_block "$source_block" \
  --argjson filters_block "$filters_block" \
  --argjson total_sz "$total_bytes" \
  '{
    manifest_version: 1,
    generated_at_utc: $gen_at,
    generated_by:     $gen_by,
    source:           $source_block,
    filters:          $filters_block,
    sessions:         .,
    totals: {
      session_count:    (. | length),
      total_size_bytes: $total_sz
    },
    sanitized: false,
    archived:  false
  }' \
  "$manifest_entries" \
  > "$OUT_DIR/manifest.json"

log "manifest : $OUT_DIR/manifest.json"
log "total    : $bundle_total session(s) from ${#bundled_encoded[@]} project(s), $total_bytes bytes"
log "done"

printf '%s\n' "$OUT_DIR"
