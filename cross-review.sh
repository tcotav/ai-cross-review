#!/usr/bin/env bash
# Minimal cross-vendor code review harness.
#
# Ledger-based: findings.md is the single shared artifact reviewers and the
# author read/append to. This script only automates the mechanical parts —
# freezing the diff, invoking a reviewer CLI headlessly, and appending its
# output under a round header. The author ("respond") step is usually better
# run interactively in your normal session; `respond` here exists for when
# you want to script that too.
set -euo pipefail

# Resolve through symlinks (e.g. ~/bin/cross-review.sh -> this repo) so
# prompts/ is always found relative to the real script, not the link.
SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
ROOT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SESSIONS_ROOT="${CROSS_REVIEW_HOME:-.cross-review}"

usage() {
  cat <<'EOF'
Usage:
  cross-review.sh init <slug> [--base <git-ref>]
      Start a session: .cross-review/<timestamp>-<slug>/
      Freezes the current diff and creates task.md + findings.md stubs.

  cross-review.sh review <session-dir> --with codex|agy|claude
      Re-freeze the diff, run the named reviewer headlessly against
      task.md + diff.patch + findings.md, append its output as a new round.

  cross-review.sh respond <session-dir> --with codex|agy|claude
      Run the named tool as the author role against the open findings.
      Usually you'd do this yourself interactively instead.

  cross-review.sh status <session-dir>
      Print per-status counts (by each finding's final status, not raw
      line matches) plus a listing of open and disputed findings.

Env:
  CROSS_REVIEW_HOME   override the sessions root (default: .cross-review)
EOF
}

next_round() {
  local findings="$1"
  local n
  n="$(grep -c '^## Round ' "$findings" 2>/dev/null || true)"
  echo "$((n + 1))"
}

stored_base() {
  local dir="$1"
  [[ -f "$dir/base" ]] && cat "$dir/base" || true
}

# mkdir is atomic even on network filesystems, unlike flock (which isn't
# available on macOS by default anyway) or a lock file written with `>`.
# An EXIT trap (not RETURN — that fires on every function return, not
# just process exit) releases it however the script ends: success,
# error under set -e, or signal. The trap calls a named function rather
# than an interpolated string — session-dir is caller-controlled, and a
# path containing a single quote could otherwise break out of the
# trap's quoting and inject shell commands.
CROSS_REVIEW_LOCKDIR=""

release_lock() {
  [[ -n "$CROSS_REVIEW_LOCKDIR" ]] && rmdir -- "$CROSS_REVIEW_LOCKDIR" 2>/dev/null
  return 0
}

acquire_lock() {
  local dir="$1" waited=0
  CROSS_REVIEW_LOCKDIR="$dir/.lock"
  while ! mkdir -- "$CROSS_REVIEW_LOCKDIR" 2>/dev/null; do
    if (( waited >= 30 )); then
      echo "Could not acquire lock on $dir after 30s (stale lock at $CROSS_REVIEW_LOCKDIR?)" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  trap release_lock EXIT
}

freeze_diff() {
  local dir="$1" base="${2:-}"
  if [[ -n "$base" ]]; then
    git diff "$base" > "$dir/diff.patch"
  else
    git diff HEAD > "$dir/diff.patch"
  fi
}

# mode is "review" (must not write to the repo) or "author" (needs write
# access to actually fix things).
run_tool() {
  local tool="$1" mode="$2" prompt_file="$3"
  case "$tool" in
    codex)
      # Verified against real codex-cli 0.153.2: prompt piped via stdin
      # (avoids ARG_MAX issues with large diffs), sandbox enforces the
      # read-only guarantee at the tool level instead of relying on the
      # prompt alone, -o gives us just the final message instead of the
      # full event transcript.
      local sandbox="read-only"
      [[ "$mode" == "author" ]] && sandbox="workspace-write"
      local out
      out="$(mktemp)"
      codex exec --sandbox "$sandbox" -o "$out" - < "$prompt_file" > /dev/null 2>&1
      cat "$out"
      rm -f "$out"
      ;;
    agy)
      # Untested — no agy install available when this was written. Antigravity
      # docs (antigravity.google/docs/cli/headless) show plain `agy -p
      # "<prompt>"` as already giving plain-text output on stdout, with
      # `--output-format json` as an opt-in for structured output — so we
      # deliberately don't pass --output-format at all here rather than
      # guess at an unconfirmed "text" value. Adjust once you can verify
      # against a real install, e.g. stdin support and a read-only/plan
      # flag equivalent to codex's --sandbox read-only.
      agy -p "$(cat "$prompt_file")"
      ;;
    claude)
      # If this hangs for minutes with no output, it's almost certainly
      # an invalid ANTHROPIC_API_KEY env var (claude -p retries 401s 11x
      # with backoff before surfacing anything) — not this harness. See
      # README "Status per tool".
      local perm="plan"
      [[ "$mode" == "author" ]] && perm="acceptEdits"
      claude -p --permission-mode "$perm" --output-format text < "$prompt_file"
      ;;
    *)
      echo "Unknown tool: $tool (expected codex|agy|claude)" >&2
      exit 1
      ;;
  esac
}

cmd_init() {
  local slug="" base=""
  slug="${1:?slug required}"; shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done

  if [[ "$slug" == *"/"* || "$slug" == *".."* || -z "$slug" ]]; then
    echo "Invalid slug: must be non-empty and contain no '/' or '..'" >&2
    exit 1
  fi

  local dir="$SESSIONS_ROOT/$(date -u +%Y%m%d-%H%M%S)-${slug}"
  # mkdir -p on the shared parent is safe to race (idempotent, no data to
  # lose there); mkdir on the exact leaf dir is the atomic check-and-create
  # for the part that actually holds session data — a separate
  # [[ -e "$dir" ]] check followed by a create is a TOCTOU race between
  # concurrent init calls with the same timestamp+slug.
  mkdir -p "$SESSIONS_ROOT"
  if ! mkdir "$dir" 2>/dev/null; then
    echo "Session dir already exists, refusing to overwrite: $dir" >&2
    exit 1
  fi

  cat > "$dir/task.md" <<'EOF'
<!-- Describe the goal/spec for this change. This is handed to every
     reviewer and to the author role verbatim — the more concrete, the
     better the findings. -->
EOF

  # Always pin an immutable commit SHA, whether --base was given or not.
  # A supplied ref like a branch name (e.g. --base main) is just as
  # mutable as the implicit HEAD default: if main moves before a later
  # review, git diff "$base" silently changes the session's baseline.
  # Plain rev-parse (not ^{commit}) so a valid non-commit base like the
  # empty-tree hash (used for "diff the whole history" sessions) still
  # resolves — it only needs to pass through unchanged, whereas ^{commit}
  # peeling rejects it outright since it dereferences to a tree, not a
  # commit.
  local resolved_base="${base:-HEAD}"
  resolved_base="$(git rev-parse "$resolved_base")"
  echo "$resolved_base" > "$dir/base"

  freeze_diff "$dir" "$resolved_base"

  cat > "$dir/findings.md" <<EOF
# Findings — ${slug}

<!-- Reviewers append "## F<n>" entries below under a "## Round N" header.
     The author appends "### Response (author)" blocks under each finding.
     Don't hand-edit someone else's entry — append, don't rewrite. -->
EOF

  echo "$dir"
}

cmd_review() {
  local dir="${1:?session dir required}"; shift
  local tool=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with) tool="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$tool" ]] || { echo "--with codex|agy|claude is required" >&2; exit 1; }

  acquire_lock "$dir"

  freeze_diff "$dir" "$(stored_base "$dir")"
  local round
  round="$(next_round "$dir/findings.md")"

  local prompt_file
  prompt_file="$(mktemp)"

  {
    cat "$ROOT_DIR/prompts/review.md"
    echo
    echo "## Round number for this run: $round"
    echo
    echo "## Task"
    cat "$dir/task.md"
    echo
    echo "## Diff under review"
    echo '```diff'
    cat "$dir/diff.patch"
    echo '```'
    echo
    echo "## Findings so far"
    cat "$dir/findings.md"
  } > "$prompt_file"

  local output
  output="$(run_tool "$tool" review "$prompt_file")"
  rm -f "$prompt_file"

  {
    echo
    echo "## Round $round — reviewer:$tool — $(date -u +%FT%TZ)"
    echo
    echo "$output"
  } >> "$dir/findings.md"

  echo "Appended round $round ($tool) to $dir/findings.md"
}

cmd_respond() {
  local dir="${1:?session dir required}"; shift
  local tool=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with) tool="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$tool" ]] || { echo "--with codex|agy|claude is required" >&2; exit 1; }

  acquire_lock "$dir"

  freeze_diff "$dir" "$(stored_base "$dir")"
  local round
  round="$(next_round "$dir/findings.md")"

  local prompt_file
  prompt_file="$(mktemp)"

  {
    cat "$ROOT_DIR/prompts/respond.md"
    echo
    echo "## Round number for this run: $round"
    echo
    echo "## Task"
    cat "$dir/task.md"
    echo
    echo "## Diff under review"
    echo '```diff'
    cat "$dir/diff.patch"
    echo '```'
    echo
    echo "## Findings so far"
    cat "$dir/findings.md"
  } > "$prompt_file"

  # Note: this invokes the tool headlessly, but fixing code well usually
  # wants full interactive tool use. This exists for scripting convenience,
  # not as the recommended default.
  run_tool "$tool" author "$prompt_file"
  rm -f "$prompt_file"

  echo "Ran $tool as author over $dir/findings.md — review its edits and"
  echo "confirm it appended Response blocks before the next review round."
}

# Parses findings.md into one tab-separated row per finding:
#   id \t final_status \t severity \t file \t summary
# "final_status" is whichever Status: line occurs LAST inside that
# finding's block, so a finding that started open and later got a
# "### Response (author)" with Status: fixed is counted once, as fixed —
# not once for each line (a naive grep -c per status double-counts these).
parse_findings() {
  local findings="$1"
  awk '
    function emit() {
      if (fid != "") {
        printf "%s\t%s\t%s\t%s\t%s\n", fid, status, severity, file, summary
      }
    }
    /^## F[0-9]+/ {
      emit()
      line = $0
      sub(/^## /, "", line)
      # Use sub() to strip through the separator rather than substr()
      # arithmetic — this awk counts string offsets in bytes, and the
      # em dash is a multi-byte UTF-8 character, so a fixed "+3" landed
      # mid-character and corrupted the first byte of the summary.
      if (line ~ / — /) {
        fid = line
        sub(/ — .*/, "", fid)
        summary = line
        sub(/^F[0-9]+ — /, "", summary)
      } else {
        fid = line
        summary = ""
      }
      status = ""
      severity = ""
      file = ""
      next
    }
    fid != "" && /^Reviewer:/ {
      n = split($0, kv, "|")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", kv[i])
        if (kv[i] ~ /^Severity:/) { severity = kv[i]; sub(/^Severity: */, "", severity) }
        if (kv[i] ~ /^Status:/)   { status = kv[i];   sub(/^Status: */, "", status) }
      }
      next
    }
    fid != "" && /^Status:/ {
      n = split($0, kv, "|")
      s = kv[1]
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      sub(/^Status: */, "", s)
      status = s
      next
    }
    fid != "" && file == "" && /^File:/ {
      file = $0
      sub(/^File: */, "", file)
      next
    }
    END { emit() }
  ' "$findings"
}

cmd_status() {
  local dir="${1:?session dir required}"
  local rows
  rows="$(parse_findings "$dir/findings.md")"

  if [[ -z "$rows" ]]; then
    echo "No findings yet."
    return
  fi

  local total open fixed wontfix disputed
  total="$(echo "$rows" | wc -l | tr -d ' ')"
  open="$(echo "$rows" | awk -F'\t' '$2=="open"' | wc -l | tr -d ' ')"
  fixed="$(echo "$rows" | awk -F'\t' '$2=="fixed"' | wc -l | tr -d ' ')"
  wontfix="$(echo "$rows" | awk -F'\t' '$2=="wontfix"' | wc -l | tr -d ' ')"
  disputed="$(echo "$rows" | awk -F'\t' '$2=="disputed"' | wc -l | tr -d ' ')"

  echo "$total findings — open=$open fixed=$fixed wontfix=$wontfix disputed=$disputed"

  local open_rows
  open_rows="$(echo "$rows" | awk -F'\t' '$2=="open"')"
  if [[ -n "$open_rows" ]]; then
    echo
    echo "Open (awaiting author response):"
    echo "$open_rows" | awk -F'\t' '{printf "  %s [%s] %s — %s\n", $1, $3, $5, $4}'
  fi

  local disputed_rows
  disputed_rows="$(echo "$rows" | awk -F'\t' '$2=="disputed"')"
  if [[ -n "$disputed_rows" ]]; then
    echo
    echo "Disputed (author pushed back, reviewer should re-check):"
    echo "$disputed_rows" | awk -F'\t' '{printf "  %s [%s] %s — %s\n", $1, $3, $5, $4}'
  fi
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    review) cmd_review "$@" ;;
    respond) cmd_respond "$@" ;;
    status) cmd_status "$@" ;;
    -h|--help|"") usage ;;
    *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
