#!/usr/bin/env bash
# Synthetic test suite for cross-review.sh.
#
# No real reviewer CLIs, network, or user config are touched: codex/agy/claude are
# stubs on PATH, HOME is a throwaway dir, and every test runs in its own temp git repo.
# Plain bash (3.2-compatible, like the script itself) — no bats/shellcheck needed.
# Requires: git, jq.
#
#   tests/run.sh            run everything
#   tests/run.sh agy        run only tests whose function name contains "agy"
set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../cross-review.sh"
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_NAMES=""
CURRENT=""

command -v jq >/dev/null || { echo "tests need jq" >&2; exit 2; }
command -v git >/dev/null || { echo "tests need git" >&2; exit 2; }

# ---------------------------------------------------------------- assertions

fail() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES="$FAILED_NAMES $CURRENT"
  echo "  FAIL [$CURRENT] $1" >&2
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
  return 0
}
pass() { PASS=$((PASS + 1)); }

assert_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then pass; else fail "$3" "expected [$1] got [$2]"; fi
}
assert_contains() { # haystack needle label
  if [[ "$1" == *"$2"* ]]; then pass; else fail "$3" "missing [$2] in: $(printf '%s' "$1" | head -c 400)"; fi
}
assert_not_contains() { # haystack needle label
  if [[ "$1" != *"$2"* ]]; then pass; else fail "$3" "unexpected [$2] in: $(printf '%s' "$1" | head -c 400)"; fi
}
assert_file() { if [[ -e "$1" ]]; then pass; else fail "${2:-file should exist}" "$1"; fi; }
assert_no_file() { if [[ ! -e "$1" ]]; then pass; else fail "${2:-file should not exist}" "$1"; fi; }
assert_rc() { # expected label   (uses $RC from last cr call)
  if [[ "$RC" == "$1" ]]; then pass; else fail "$2" "exit $RC, expected $1; stderr: $(head -c 400 "$T/err")"; fi
}

# ---------------------------------------------------------------- fixtures

# Fresh sandbox: temp git repo with one commit, fake HOME, stub CLIs first on PATH.
new_sandbox() {
  T="$(cd -P "$(mktemp -d)" && pwd -P)"
  REPO="$T/repo"
  mkdir -p "$REPO" "$T/home" "$T/bin" "$T/tmp" "$T/stubstate"
  export HOME="$T/home"
  export TMPDIR="$T/tmp"
  export STUB_DIR="$T/stubstate"
  export PATH="$T/bin:$ORIG_PATH"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset CROSS_REVIEW_HOME CROSS_REVIEW_EXTRA_SENSITIVE CROSS_REVIEW_AGY_ALLOW_RULES_OK \
        CROSS_REVIEW_AGY_TIMEOUT STUB_CODEX_RC STUB_AGY_RC STUB_AGY_STDERR STUB_CLAUDE_RC STUB_SESSION_DIR 2>/dev/null || true
  export CROSS_REVIEW_MAX_FILE_DIFF_BYTES=200000 CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES=800000
  (
    cd "$REPO" || exit 1
    git init -q . && git checkout -q -b main 2>/dev/null || true
    echo "hello" > a.txt
    git add a.txt && git commit -q -m init
  )
  cd "$REPO" || exit 1
  make_stubs
}

make_stubs() {
  cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
cat > "$STUB_DIR/codex.stdin"
if [ -n "${STUB_CODEX_RC:-}" ]; then echo "codex stub failure"; exit "$STUB_CODEX_RC"; fi
cat "$STUB_CODEX_OUT" > "$out"
printf 'transcript line\ntokens used\n1,234\n'
EOF
  cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > "$STUB_DIR/claude.stdin"
if [ -n "${STUB_CLAUDE_RC:-}" ]; then echo "claude stub failure" >&2; exit "$STUB_CLAUDE_RC"; fi
cat "$STUB_CLAUDE_OUT"
EOF
  # agy stub: records cwd/args/prompt, whether the session lock was held, then emits canned JSON.
  cat > "$T/bin/agy" <<'EOF'
#!/usr/bin/env bash
pwd -P > "$STUB_DIR/agy.cwd"
printf '%s\n' "$@" > "$STUB_DIR/agy.args"
for a in "$@"; do
  case "$a" in --print=*) printf '%s' "${a#--print=}" > "$STUB_DIR/agy.prompt" ;; esac
done
if [ -n "${STUB_SESSION_DIR:-}" ]; then
  if [ -e "$STUB_SESSION_DIR/.lock" ]; then echo held > "$STUB_DIR/agy.lock"; else echo free > "$STUB_DIR/agy.lock"; fi
fi
[ -n "${STUB_AGY_STDERR:-}" ] && echo "$STUB_AGY_STDERR" >&2
cat "$STUB_AGY_JSON"
exit "${STUB_AGY_RC:-0}"
EOF
  # macOS's BSD `mktemp -d` with no template ignores $TMPDIR (it uses the per-user temp dir);
  # GNU mktemp honours it. This shim makes template-less calls honour $TMPDIR on both, so the
  # TMPDIR-based tests (scratch-in-repo refusal, temp cleanup) behave the same everywhere.
  local real_mktemp; real_mktemp="$(PATH="$ORIG_PATH" command -v mktemp)"
  cat > "$T/bin/mktemp" <<EOF
#!/usr/bin/env bash
has_template=""
for a in "\$@"; do case "\$a" in -*) ;; *) has_template=1 ;; esac; done
if [ -z "\$has_template" ]; then exec "$real_mktemp" "\$@" "\${TMPDIR:-/tmp}/tmp.XXXXXXXX"; fi
exec "$real_mktemp" "\$@"
EOF
  # date shim: cmd_review calls `date` while writing the round header into findings.md, i.e.
  # after the reviewer returned but before the append lands. Recording whether the session lock
  # still exists at that instant lets a test catch the lock being released too early.
  local real_date; real_date="$(PATH="$ORIG_PATH" command -v date)"
  cat > "$T/bin/date" <<EOF
#!/usr/bin/env bash
if [ -n "\${STUB_SESSION_DIR:-}" ]; then
  if [ -e "\$STUB_SESSION_DIR/.lock" ]; then echo held >> "\$STUB_DIR/date.lock"; else echo free >> "\$STUB_DIR/date.lock"; fi
fi
exec "$real_date" "\$@"
EOF
  chmod +x "$T/bin/codex" "$T/bin/claude" "$T/bin/agy" "$T/bin/mktemp" "$T/bin/date"
}

teardown() { cd / || true; rm -rf "$T"; }

# Run the script under test; sets RC, and leaves stdout/stderr in $T/out, $T/err.
cr() {
  RC=0
  "$SCRIPT" "$@" > "$T/out" 2> "$T/err" || RC=$?
  OUT="$(cat "$T/out")"
  ERR="$(cat "$T/err")"
}

N=0
# Starts a session and sets SESSION. Extra args pass through to init.
start_session() {
  N=$((N + 1))
  cr init "t$N" "$@"
  SESSION="$REPO/$OUT"
  export STUB_SESSION_DIR="$SESSION"
}

good_findings() {
  cat > "$T/findings.out" <<'EOF'
## F1 — Off-by-one in loop
File: a.txt:1
Reviewer: stub | Severity: major | Status: open

Details here.
EOF
}

agy_json_ok() {
  cat > "$T/agy.json" <<'EOF'
{"status":"SUCCESS","response":"## F1 — From agy\nFile: a.txt:1\nReviewer: agy | Severity: minor | Status: open\n","usage":{"total_tokens":4321}}
EOF
  # jq -r on a JSON "\n" gives real newlines; keep it so the ledger format check passes.
  export STUB_AGY_JSON="$T/agy.json"
}

# ---------------------------------------------------------------- init

test_init_creates_session_files() {
  start_session
  assert_rc 0 "init succeeds"
  for f in task.md findings.md base repo-root diff.patch; do assert_file "$SESSION/$f" "init creates $f"; done
  assert_eq "$(git rev-parse HEAD)" "$(cat "$SESSION/base")" "base pins an immutable commit sha"
  assert_eq "$REPO" "$(cat "$SESSION/repo-root")" "repo-root recorded"
}

test_init_rejects_bad_slugs() {
  cr init "a/b"; assert_rc 1 "slash in slug rejected"
  cr init "a..b"; assert_rc 1 "dotdot in slug rejected"
  cr init; assert_rc 1 "missing slug rejected"
}

test_init_base_ref_resolved_to_sha() {
  echo two > b.txt; git add b.txt; git commit -q -m two
  start_session --base HEAD~1
  assert_eq "$(git rev-parse HEAD~1)" "$(cat "$SESSION/base")" "--base ref resolved to a sha"
  assert_contains "$(cat "$SESSION/diff.patch")" "b.txt" "diff against older base includes later commit"
}

test_init_unknown_arg() {
  cr init foo --bogus; assert_rc 1 "unknown init arg rejected"
}

test_diff_includes_modified_and_untracked() {
  echo changed >> a.txt
  echo brandnew > new.txt
  start_session
  local d; d="$(cat "$SESSION/diff.patch")"
  assert_contains "$d" "+changed" "modified tracked file in diff"
  assert_contains "$d" "new.txt" "untracked file in diff"
  assert_contains "$d" "+brandnew" "untracked content in diff"
}

test_diff_excludes_session_dirs() {
  start_session   # first session exists in repo as untracked files
  N=$((N + 1)); cr init "other$N"
  assert_not_contains "$(cat "$OUT/diff.patch")" ".cross-review" "other sessions' files not folded into diff"
}

test_sessions_root_at_repo_root_refused() {
  export CROSS_REVIEW_HOME="$REPO"
  cr init rootcase
  assert_rc 1 "CROSS_REVIEW_HOME == repo root refused"
  assert_contains "$ERR" "repository root" "explains why"
}

# ---------------------------------------------------------------- sensitive files

SECRET="SUPER_SECRET_TOKEN_123"

test_sensitive_untracked_env_stubbed() {
  echo "KEY=$SECRET" > .env
  start_session
  local d; d="$(cat "$SESSION/diff.patch")"
  assert_not_contains "$d" "$SECRET" "secret not in diff"
  assert_contains "$d" "diff --git a/.env b/.env" "stub keeps a diff header"
  assert_contains "$d" "sensitive-file pattern" "stub explains omission"
  assert_contains "$ERR" "Warning: .env" "warns on stderr"
}

test_sensitive_templates_allowed() {
  echo "KEY=placeholder" > .env.example
  echo "ssh-ed25519 AAAA" > id_ed25519.pub
  start_session
  local d; d="$(cat "$SESSION/diff.patch")"
  assert_contains "$d" "+KEY=placeholder" ".env.example content passes through"
  assert_contains "$d" "ssh-ed25519 AAAA" "*.pub passes through"
}

test_sensitive_various_patterns() {
  local f
  for f in server.pem tls.key credentials.json service-account-prod.json secrets.yaml id_rsa .npmrc; do
    echo "$SECRET" > "$f"
  done
  start_session
  assert_not_contains "$(cat "$SESSION/diff.patch")" "$SECRET" "none of the sensitive-named files leak"
}

test_sensitive_extra_globs() {
  echo "$SECRET" > prod-vars.yaml
  export CROSS_REVIEW_EXTRA_SENSITIVE="prod-*.yaml"
  start_session
  assert_not_contains "$(cat "$SESSION/diff.patch")" "$SECRET" "CROSS_REVIEW_EXTRA_SENSITIVE honoured"
}

test_sensitive_rename_from_env() {
  echo "KEY=$SECRET" > .env
  git add .env; git commit -q -m env
  git mv .env data.txt
  start_session
  assert_not_contains "$(cat "$SESSION/diff.patch")" "$SECRET" "renamed secret not leaked"
  assert_contains "$ERR" "renamed from .env" "rename source reported"
}

test_sensitive_copy_under_innocuous_name() {
  echo ".env" > .gitignore; git add .gitignore; git commit -q -m ign
  echo "KEY=$SECRET" > .env          # gitignored, never tracked
  cp .env notes.txt                   # exact copy, innocent name
  start_session
  assert_not_contains "$(cat "$SESSION/diff.patch")" "$SECRET" "exact copy of a secret not leaked"
  assert_contains "$ERR" "same content as .env" "copy source reported"
}

test_sensitive_deleted_copy_not_leaked() {
  echo ".env" > .gitignore; echo "KEY=$SECRET" > config.txt
  git add .gitignore config.txt; git commit -q -m cfg
  echo "KEY=$SECRET" > .env
  rm config.txt                       # deletion would print the secret as '-' lines
  start_session
  assert_not_contains "$(cat "$SESSION/diff.patch")" "$SECRET" "deleted copy of a secret not leaked"
  assert_contains "$ERR" "previous version had the same content" "base-side match reported"
}

# ---------------------------------------------------------------- size caps

test_per_file_cap_stubs_big_file() {
  export CROSS_REVIEW_MAX_FILE_DIFF_BYTES=400
  head -c 2000 /dev/zero | tr '\0' 'x' > big.txt
  echo small > small.txt
  start_session
  local d; d="$(cat "$SESSION/diff.patch")"
  assert_contains "$d" "diff --git a/big.txt b/big.txt" "stub header for oversized file"
  assert_contains "$d" "over the 400-byte per-file cap" "stub explains cap"
  assert_not_contains "$d" "xxxxxxxxxxxxxxxx" "oversized content omitted"
  assert_contains "$d" "+small" "small files unaffected"
}

test_total_cap_warns_but_succeeds() {
  export CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES=10
  echo "some change" >> a.txt
  start_session
  assert_rc 0 "total cap is non-fatal"
  assert_contains "$ERR" "total-diff threshold" "warning emitted"
}

# ---------------------------------------------------------------- status / parse_findings

write_ledger() {
  cat > "$SESSION/findings.md" <<'EOF'
# Findings — x

## Round 1 — reviewer:codex — 2026-01-01T00:00:00Z — tokens: 1000

## F1 — fixed one
File: a.txt:1
Reviewer: codex | Severity: major | Status: open

### Response (author)
Status: fixed

## F2 — needs a fix
File: src/a.sh:3
Reviewer: codex | Severity: major | Status: open

## Round 2 — reviewer:agy — 2026-01-01T00:00:00Z — tokens: 500

## F3 — security call
File: b.sh:9
Reviewer: agy | Severity: critical | Status: open

### Response (author)
Status: open

## F4 — pushback
File: c.sh:2
Reviewer: agy | Severity: minor | Status: open

### Response (author)
Status: disputed

## F5 — not worth it
File: d.sh:2
Reviewer: agy | Severity: nit | Status: open

### Response (author)
Status: wontfix

## Round 3 — reviewer:claude — 2026-01-01T00:00:00Z — tokens: unknown
EOF
}

test_status_counts_final_status_once() {
  start_session
  write_ledger
  cr status "$SESSION"
  assert_rc 0 "status succeeds"
  assert_contains "$OUT" "5 findings — open=2 fixed=1 wontfix=1 disputed=1" "each finding counted once by last status"
  assert_contains "$OUT" "Tokens: 1500 across 2 round(s) (1 round(s) unknown" "token sum with unknown round"
}

test_status_sections() {
  start_session
  write_ledger
  cr status "$SESSION"
  assert_contains "$OUT" "Open (awaiting author response):" "awaiting section"
  assert_contains "$OUT" "F2 [major] needs a fix — src/a.sh:3" "awaiting row with em dash summary intact"
  assert_contains "$OUT" "needs human sign-off" "sign-off section"
  assert_contains "$OUT" "F3 [critical] security call" "responded-but-open lands in sign-off"
  assert_contains "$OUT" "Disputed (author pushed back" "disputed section"
  assert_contains "$OUT" "F4 [minor] pushback" "disputed row"
}

test_status_empty_ledger() {
  start_session
  cr status "$SESSION"
  assert_contains "$OUT" "No findings yet." "empty ledger message"
}

test_status_no_findings_but_tokens() {
  start_session
  printf '# F\n\n## Round 1 — reviewer:codex — t — tokens: 77\n\nNo new findings.\n' > "$SESSION/findings.md"
  cr status "$SESSION"
  assert_contains "$OUT" "No findings yet." "no findings"
  assert_contains "$OUT" "Tokens: 77 across 1 round(s)" "tokens still reported"
}

# ---------------------------------------------------------------- review: codex / claude

test_review_codex_appends_round() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  echo "TASK-MARKER-XYZ" > "$SESSION/task.md"
  cr review "$SESSION" --with codex
  assert_rc 0 "review succeeds"
  local f; f="$(cat "$SESSION/findings.md")"
  assert_contains "$f" "## Round 1 — reviewer:codex" "round header"
  assert_contains "$f" "tokens: 1234" "codex token count scraped and comma-stripped"
  assert_contains "$f" "## F1 — Off-by-one in loop" "findings appended"
  local p; p="$(cat "$STUB_DIR/codex.stdin")"
  assert_contains "$p" "TASK-MARKER-XYZ" "task.md handed to reviewer"
  assert_contains "$p" "## Round number for this run: 1" "round number in prompt"
  assert_contains "$p" "## Diff under review" "diff section in prompt"
}

test_review_second_round_increments() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with codex
  sed -i.bak 's/F1/F2/' "$T/findings.out"
  cr review "$SESSION" --with codex
  assert_contains "$(cat "$SESSION/findings.md")" "## Round 2 — reviewer:codex" "second round numbered 2"
}

test_review_no_new_findings_accepted() {
  echo "No new findings." > "$T/findings.out"; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with codex
  assert_rc 0 "explicit no-findings line accepted"
  assert_contains "$(cat "$SESSION/findings.md")" "No new findings." "recorded"
}

test_review_malformed_output_rejected() {
  echo "I reviewed it and everything looks mostly fine, but check the loop." > "$T/findings.out"
  export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with codex
  assert_rc 1 "prose-only reply fails"
  assert_not_contains "$(cat "$SESSION/findings.md")" "Round 1" "not appended to ledger"
  assert_file "$SESSION/round-1-rejected.md" "raw reply preserved"
  assert_contains "$ERR" "round-1-rejected.md" "points at rejected file"
}

test_review_codex_failure_not_recorded() {
  export STUB_CODEX_RC=3 STUB_CODEX_OUT=/dev/null
  start_session
  cr review "$SESSION" --with codex
  assert_rc 1 "codex failure propagates"
  assert_contains "$ERR" "codex exec failed (exit 3)" "failure surfaced"
  assert_not_contains "$(cat "$SESSION/findings.md")" "Round 1" "no empty round recorded"
}

test_review_model_flag_in_header() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with codex --model gpt-test
  assert_contains "$(cat "$SESSION/findings.md")" "reviewer:codex (gpt-test)" "model recorded in round header"
}

test_review_claude_leg() {
  good_findings; export STUB_CLAUDE_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with claude
  assert_rc 0 "claude leg succeeds"
  assert_contains "$(cat "$SESSION/findings.md")" "reviewer:claude" "round recorded"
  assert_contains "$(cat "$SESSION/findings.md")" "tokens: unknown" "claude tokens unknown"
}

test_review_claude_failure() {
  export STUB_CLAUDE_RC=2 STUB_CLAUDE_OUT=/dev/null
  start_session
  cr review "$SESSION" --with claude
  assert_rc 1 "claude failure propagates"
  assert_contains "$ERR" "claude -p failed (exit 2)" "failure surfaced"
}

test_review_arg_validation() {
  start_session
  cr review "$SESSION"; assert_rc 1 "--with required"
  cr review "$SESSION" --with nope; assert_rc 1 "unknown tool rejected"
  assert_contains "$ERR" "Unknown tool" "message names the problem"
  cr review "$SESSION" --with codex --bogus; assert_rc 1 "unknown flag rejected"
}

test_review_runs_from_recorded_repo_root() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  echo "late-change" >> a.txt
  mkdir -p "$T/elsewhere"
  cd "$T/elsewhere"
  cr review "$SESSION" --with codex
  cd "$REPO"
  assert_rc 0 "review works from a different cwd"
  assert_contains "$(cat "$SESSION/diff.patch")" "+late-change" "diff re-frozen against the recorded repo"
}

test_review_refreezes_diff() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  echo "after-init" >> a.txt
  cr review "$SESSION" --with codex
  assert_contains "$(cat "$STUB_DIR/codex.stdin")" "+after-init" "reviewer sees changes made after init"
}

# Regression: cmd_review/cmd_respond create a prompt file (the full diff) and a token file in
# $TMPDIR; they used to be removed only after run_tool returned, so any reviewer failure left
# them behind. Nothing of the script's own may survive any exit path.
test_no_temp_leak_on_any_exit_path() {
  start_session
  echo "diff-content-marker" >> a.txt

  export STUB_CODEX_RC=3 STUB_CODEX_OUT=/dev/null
  cr review "$SESSION" --with codex
  assert_rc 1 "codex failure"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after codex failure"

  cr respond "$SESSION" --with codex
  assert_rc 1 "codex author failure"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after codex respond failure"

  export STUB_CLAUDE_RC=2 STUB_CLAUDE_OUT=/dev/null
  cr review "$SESSION" --with claude
  assert_rc 1 "claude failure"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after claude failure"

  echo '{"status":"ERROR","response":"x","usage":{"total_tokens":1}}' > "$T/agy.json"
  export STUB_AGY_JSON="$T/agy.json"
  cr review "$SESSION" --with agy
  assert_rc 1 "agy failure"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after agy failure"

  echo "prose, no findings format" > "$T/findings.out"
  unset STUB_CODEX_RC; export STUB_CODEX_OUT="$T/findings.out"
  cr review "$SESSION" --with codex
  assert_rc 1 "malformed output"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after rejected output"

  cr review "$SESSION" --with bogus
  assert_rc 1 "unknown tool"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after unknown tool"

  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  cr review "$SESSION" --with codex
  assert_rc 0 "success"
  assert_eq "" "$(ls -A "$T/tmp")" "no temp files after success"
}

# ---------------------------------------------------------------- respond

test_respond_codex_runs_author_role() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr respond "$SESSION" --with codex
  assert_rc 0 "respond succeeds"
  assert_contains "$OUT" "as author over" "reports it ran as author"
  assert_contains "$(cat "$STUB_DIR/codex.stdin")" "Findings ledger (append your Response blocks here)" "author prompt used"
}

test_respond_agy_refused() {
  start_session
  cr respond "$SESSION" --with agy
  assert_rc 1 "agy cannot be author"
  assert_contains "$ERR" "can't run as author headlessly" "explains why"
}

# ---------------------------------------------------------------- locking

test_lock_released_after_success_and_failure() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with codex
  assert_no_file "$SESSION/.lock" "lock released after success"
  echo "prose only" > "$T/findings.out"
  cr review "$SESSION" --with codex
  assert_no_file "$SESSION/.lock" "lock released after failure"
}

test_lock_stale_owner_reclaimed() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  ( exit 0 ) & local dead=$!; wait "$dead" 2>/dev/null
  echo "$dead" > "$SESSION/.lock"
  cr review "$SESSION" --with codex
  assert_rc 0 "dead owner's lock reclaimed"
  assert_contains "$ERR" "Reclaiming lock" "reclaim noted"
  assert_no_file "$SESSION/.lock" "lock gone afterwards"
}

# ---------------------------------------------------------------- agy leg

agy_setup() { agy_json_ok; start_session; }

test_agy_happy_path() {
  agy_setup
  cr review "$SESSION" --with agy
  assert_rc 0 "agy review succeeds"
  local f; f="$(cat "$SESSION/findings.md")"
  assert_contains "$f" "reviewer:agy" "round header names agy"
  assert_contains "$f" "tokens: 4321" "tokens from usage.total_tokens"
  assert_contains "$f" "## F1 — From agy" "response appended"
  assert_contains "$(cat "$STUB_DIR/agy.args")" "--sandbox" "--sandbox passed"
  assert_contains "$(cat "$STUB_DIR/agy.args")" "--output-format" "json output requested"
}

test_agy_runs_in_empty_scratch_outside_repo() {
  agy_setup
  cr review "$SESSION" --with agy
  local cwd; cwd="$(cat "$STUB_DIR/agy.cwd")"
  case "$cwd/" in "$REPO"/*) fail "agy ran inside the repo: $cwd" ;; *) pass ;; esac
  assert_no_file "$cwd" "scratch dir removed after run"
  assert_eq "" "$(ls -A "$T/tmp")" "no leftover temp files"
}

test_agy_prompt_inline_with_no_tools_notice() {
  agy_setup
  cr review "$SESSION" --with agy
  local p; p="$(cat "$STUB_DIR/agy.prompt")"
  assert_contains "$p" "you have no tool access" "no-tools preamble"
  assert_contains "$p" "## Diff under review" "diff inline"
}

test_agy_model_flag() {
  agy_setup
  cr review "$SESSION" --with agy --model gem-test
  assert_contains "$(cat "$STUB_DIR/agy.args")" "gem-test" "model passed through"
  assert_contains "$(cat "$SESSION/findings.md")" "(gem-test)" "model in header"
}

test_agy_scratch_inside_repo_refused() {
  agy_setup
  mkdir -p "$REPO/tmpin"
  export TMPDIR="$REPO/tmpin"
  cr review "$SESSION" --with agy
  assert_rc 1 "TMPDIR inside repo refused"
  assert_contains "$ERR" "inside the repo under review" "explains"
  assert_no_file "$STUB_DIR/agy.cwd" "agy never launched"
  assert_eq "" "$(find "$REPO/tmpin" -mindepth 1 -type d)" "scratch dir cleaned up after refusal"
}

test_agy_scratch_via_symlinked_tmpdir_inside_repo_refused() {
  agy_setup
  mkdir -p "$REPO/real"
  ln -s "$REPO/real" "$T/linktmp"
  export TMPDIR="$T/linktmp"
  cr review "$SESSION" --with agy
  assert_rc 1 "symlinked TMPDIR resolving into repo refused"
  assert_no_file "$STUB_DIR/agy.cwd" "agy never launched"
}

# Writes agy settings (relative to fake HOME) and runs a review; expects refusal.
agy_grant_case() { # label settings-file-relative json expect(refuse|allow)
  local label="$1" rel="$2" json="$3" expect="$4"
  rm -f "$HOME/.gemini/antigravity-cli/settings.json" "$HOME/.gemini/config/config.json"
  rm -rf "$HOME/.gemini/config/projects"
  mkdir -p "$(dirname "$HOME/$rel")"
  printf '%s' "$json" > "$HOME/$rel"
  rm -f "$STUB_DIR/agy.cwd"
  cr review "$SESSION" --with agy
  if [[ "$expect" == refuse ]]; then
    assert_rc 1 "$label: refused"
    assert_contains "$ERR" "Refusing to run agy" "$label: refusal message"
    assert_no_file "$STUB_DIR/agy.cwd" "$label: agy not launched"
  else
    assert_rc 0 "$label: allowed"
    assert_file "$STUB_DIR/agy.cwd" "$label: agy launched"
  fi
}

test_agy_grant_check_settings_json() {
  agy_setup
  local S=.gemini/antigravity-cli/settings.json
  agy_grant_case "allow rule present" "$S" '{"permissions":{"allow":["Bash(ls)"]}}' refuse
  agy_grant_case "empty allow array" "$S" '{"permissions":{"allow":[]}}' allow
  agy_grant_case "deny-only" "$S" '{"permissions":{"deny":["Bash(rm)"]}}' allow
  agy_grant_case "no permissions key" "$S" '{"theme":"dark"}' allow
  agy_grant_case "allow is not an array" "$S" '{"permissions":{"allow":true}}' refuse
  agy_grant_case "permissions is a string" "$S" '{"permissions":"yes"}' refuse
  agy_grant_case "permissions null" "$S" '{"permissions":null}' allow
  agy_grant_case "invalid json fails closed" "$S" '{not json' refuse
  agy_grant_case "two top-level values fails closed" "$S" '{} {"permissions":{"allow":["x"]}}' refuse
  agy_grant_case "empty file ok" "$S" '' allow
  agy_grant_case "whitespace-only file ok" "$S" '
' allow
  agy_grant_case "top-level array fails closed" "$S" '[1]' refuse
}

test_agy_grant_check_global_config_and_projects() {
  agy_setup
  local C=.gemini/config/config.json
  agy_grant_case "global grants with allow" "$C" '{"globalPermissionGrants":{"allow":[{"x":1}]}}' refuse
  agy_grant_case "global grants empty" "$C" '{"globalPermissionGrants":{"allow":[],"deny":[1]}}' allow
  agy_grant_case "nested permissionGrants with allow" "$C" '{"a":{"b":{"permissionGrants":{"allow":["x"]}}}}' refuse
  agy_grant_case "V2Migrated flag is harmless" "$C" '{"permissionGrantsV2Migrated":true}' allow
  agy_grant_case "project grants with allow" ".gemini/config/projects/p1.json" '{"permissionGrants":{"allow":["x"]}}' refuse
  agy_grant_case "project record without grants" ".gemini/config/projects/p2.json" '{"name":"p"}' allow
}

test_agy_allow_rules_override_exactly_one() {
  agy_setup
  mkdir -p "$HOME/.gemini/antigravity-cli"
  echo '{"permissions":{"allow":["Bash(ls)"]}}' > "$HOME/.gemini/antigravity-cli/settings.json"
  export CROSS_REVIEW_AGY_ALLOW_RULES_OK=0
  cr review "$SESSION" --with agy
  assert_rc 1 "OK=0 does not disable the check"
  export CROSS_REVIEW_AGY_ALLOW_RULES_OK=true
  cr review "$SESSION" --with agy
  assert_rc 1 "OK=true does not disable the check"
  export CROSS_REVIEW_AGY_ALLOW_RULES_OK=1
  cr review "$SESSION" --with agy
  assert_rc 0 "OK=1 disables the check"
}

test_agy_failure_shapes() {
  agy_setup
  # non-zero exit
  STUB_AGY_RC=4 cr review "$SESSION" --with agy
  assert_rc 1 "non-zero exit fails"
  assert_contains "$ERR" "agy failed (exit 4" "reports exit code"
  # status != SUCCESS
  echo '{"status":"ERROR","response":"x","usage":{"total_tokens":1}}' > "$T/agy.json"
  cr review "$SESSION" --with agy
  assert_rc 1 "non-SUCCESS status fails"
  # empty response with denied actions
  echo '{"status":"SUCCESS","response":"","denied_actions":[{"action":"run_command"}],"usage":{"total_tokens":9}}' > "$T/agy.json"
  cr review "$SESSION" --with agy
  assert_rc 1 "empty response fails"
  assert_contains "$ERR" "denied: run_command" "denied actions surfaced"
  # whitespace-only response
  echo '{"status":"SUCCESS","response":"  \n ","usage":{"total_tokens":9}}' > "$T/agy.json"
  cr review "$SESSION" --with agy
  assert_rc 1 "whitespace-only response fails"
  # unparseable output
  echo 'not json at all' > "$T/agy.json"
  cr review "$SESSION" --with agy
  assert_rc 1 "garbage output fails"
  assert_not_contains "$(cat "$SESSION/findings.md")" "Round 1" "no failed run was recorded as a round"
  # agy's own temp files: its scratch dir (recorded by the stub) and its out/err capture files,
  # which are the only ones that would still contain agy's JSON. (cmd_review's own prompt/token
  # temp files are a separate, known leak on any reviewer failure, so $TMPDIR isn't asserted empty.)
  assert_no_file "$(cat "$STUB_DIR/agy.cwd")" "agy scratch dir removed on failure paths"
  local leaked="" lf
  for lf in "$T"/tmp/*; do
    [[ -f "$lf" ]] || continue
    case "$(cat "$lf")" in *'"status"'*|*"not json at all"*) leaked="$lf" ;; esac
  done
  assert_eq "" "$leaked" "agy out/err capture files removed on failure paths"
  assert_no_file "$SESSION/.lock" "lock released on failure"
}

test_agy_timeout_with_partial_output_fails() {
  agy_setup   # valid-looking, non-empty response...
  STUB_AGY_STDERR="[agy] print timeout after 900s with turn in progress; returning partial output" \
    cr review "$SESSION" --with agy
  assert_rc 1 "...but a timeout notice makes it a failure"
  assert_contains "$ERR" "timed out" "tells the user to raise the timeout"
}

test_agy_denied_actions_noted_but_recorded() {
  agy_setup
  cat > "$T/agy.json" <<'EOF'
{"status":"SUCCESS","response":"No new findings.","denied_actions":[{"action":"read_file"}],"usage":{"total_tokens":5}}
EOF
  cr review "$SESSION" --with agy
  assert_rc 0 "non-empty response with denials still succeeds"
  assert_contains "$ERR" "tool calls that were denied (read_file)" "denial noted"
}

test_agy_malformed_findings_rejected() {
  agy_setup
  echo '{"status":"SUCCESS","response":"Looks fine to me, nothing to report.","usage":{"total_tokens":5}}' > "$T/agy.json"
  cr review "$SESSION" --with agy
  assert_rc 1 "format enforcement applies to agy too"
  assert_file "$SESSION/round-1-rejected.md" "rejected output preserved"
}

test_agy_timeout_env_passed_through() {
  agy_setup
  export CROSS_REVIEW_AGY_TIMEOUT=33s
  cr review "$SESSION" --with agy
  assert_contains "$(cat "$STUB_DIR/agy.args")" "33s" "CROSS_REVIEW_AGY_TIMEOUT used"
}

test_agy_lock_held_during_run_and_released_after() {
  agy_setup
  cr review "$SESSION" --with agy
  assert_eq "held" "$(cat "$STUB_DIR/agy.lock")" "session lock held while agy runs"
  assert_no_file "$SESSION/.lock" "lock released afterwards"
  # Regression: the agy EXIT trap used to release the lock from inside run_tool's
  # command-substitution child, before the parent had appended to findings.md.
  assert_contains "$(cat "$SESSION/findings.md")" "## Round 1" "findings appended"
}

# Regression guard: the agy EXIT trap once released the session lock from inside run_tool's
# command-substitution child (bash 3.2 reports BASH_SUBSHELL=0 there), i.e. before the parent
# had appended to findings.md. The lock must be held right up to the append, for every leg.
test_lock_held_until_findings_appended_agy() {
  agy_setup
  cr review "$SESSION" --with agy
  assert_rc 0 "review succeeds"
  assert_file "$STUB_DIR/date.lock" "date probe fired while building the round header"
  assert_eq "held" "$(sort -u "$STUB_DIR/date.lock")" "lock still held when the findings entry is built"
}

test_lock_held_until_findings_appended_codex() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  start_session
  cr review "$SESSION" --with codex
  assert_eq "held" "$(sort -u "$STUB_DIR/date.lock")" "lock still held when the findings entry is built"
}

test_agy_needs_jq() {
  agy_setup
  # PATH with only the stubs plus the basics, no jq.
  local nojq="$T/nojq"; mkdir -p "$nojq"
  local c
  for c in bash env git cat mktemp rm date dirname basename readlink wc tr awk sed grep sleep ln kill head ls cp mkdir pwd uname; do
    local p; p="$(command -v "$c" 2>/dev/null || true)"; [[ -n "$p" ]] && ln -sf "$p" "$nojq/$c"
  done
  RC=0
  PATH="$T/bin:$nojq" "$SCRIPT" review "$SESSION" --with agy > "$T/out" 2> "$T/err" || RC=$?
  ERR="$(cat "$T/err")"
  assert_rc 1 "missing jq fails"
  assert_contains "$ERR" "needs jq" "says so"
}

# ---------------------------------------------------------------- misc CLI

test_cli_help_and_unknown() {
  cr --help; assert_rc 0 "--help ok"
  assert_contains "$OUT" "cross-review.sh init" "usage printed"
  cr; assert_rc 0 "no args prints usage"
  cr frobnicate; assert_rc 1 "unknown command fails"
}

test_symlinked_script_finds_prompts() {
  good_findings; export STUB_CODEX_OUT="$T/findings.out"
  ln -s "$SCRIPT" "$T/bin/cr-link"
  start_session
  RC=0; "$T/bin/cr-link" review "$SESSION" --with codex > "$T/out" 2> "$T/err" || RC=$?
  assert_rc 0 "script invoked through a symlink still finds prompts/"
}

# ---------------------------------------------------------------- runner

ORIG_PATH="$PATH"
TESTS="$(declare -F | awk '$3 ~ /^test_/ {print $3}')"
for fn in $TESTS; do
  [[ -n "$FILTER" && "$fn" != *"$FILTER"* ]] && continue
  CURRENT="$fn"
  before=$FAIL
  new_sandbox
  "$fn"
  teardown
  if (( FAIL == before )); then echo "ok   $fn"; else echo "FAIL $fn"; fi
done

echo
echo "assertions passed: $PASS, failed: $FAIL"
if (( FAIL > 0 )); then
  echo "failing tests:$(printf '%s\n' $FAILED_NAMES | sort -u | tr '\n' ' ')" >&2
  exit 1
fi
