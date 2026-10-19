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
# A single file's diff bigger than this (bytes) gets replaced with a one-line stub instead of
# its real content when freezing. Real-world trigger: a minified/single-line JSON fixture
# (~4MB before, ~4MB after) produced an ~8.8MB diff for that one file alone, tripping
# codex-cli 0.153.4's ~1,048,576-character input cap with a low-level RPC error that gave no
# hint which file caused it. A whole file rendered as one changed line has no diffable
# structure a reviewer could use anyway, so capping loses no real review value. Override for a
# one-off larger cap (e.g. a big-but-genuinely-reviewable generated file).
CROSS_REVIEW_MAX_FILE_DIFF_BYTES="${CROSS_REVIEW_MAX_FILE_DIFF_BYTES:-200000}"
# Secondary, whole-diff safety net for the case where many moderately-sized files add up past a
# reviewer CLI's input cap even though no single file trips the per-file cap above. Non-fatal
# (a warning, not exit 1) -- this can't know any given tool's actual limit (they differ and
# change), so it errs toward letting a legitimately large diff through with a heads-up rather
# than blocking one that would have worked.
CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES="${CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES:-800000}"
# Basename globs for files whose content is replaced with a stub instead of being frozen into
# diff.patch -- that file goes verbatim into a third-party reviewer's prompt, and untracked
# files are included as long as they aren't gitignored, so an un-ignored .env or private key
# would otherwise be shipped to another vendor. Matched case-sensitively against the basename
# only. Templates (.env.example etc.) and public keys (*.pub) are allowed through by
# is_sensitive_path. Add your own
# with CROSS_REVIEW_EXTRA_SENSITIVE (space-separated globs, e.g. "*.tfvars prod-*.yaml").
CROSS_REVIEW_SENSITIVE_PATTERNS='.env .env.* *.env *.pem *.key *.p12 *.pfx *.jks *.keystore id_rsa id_rsa.* id_dsa id_dsa.* id_ecdsa id_ecdsa.* id_ed25519 id_ed25519.* .netrc .npmrc .pypirc .pgpass credentials credentials.json *.credentials.json service-account*.json secrets.* *.secret *.secrets'

usage() {
  cat <<'EOF'
Usage:
  cross-review.sh init <slug> [--base <git-ref>]
      Start a session: .cross-review/<timestamp>-<slug>/
      Freezes the current diff and creates task.md + findings.md stubs.

  cross-review.sh review <session-dir> --with codex|agy|claude [--model <name>]
      Re-freeze the diff, run the named reviewer headlessly against
      task.md + diff.patch + findings.md, append its output as a new round.
      --model pins a specific model instead of the tool's default — e.g.
      to review with the same vendor but a different model than whatever
      wrote the code.

  cross-review.sh respond <session-dir> --with codex|claude [--model <name>]
      Run the named tool as the author role against the open findings.
      Usually you'd do this yourself interactively instead. Not supported
      for agy: its headless mode auto-denies file writes.

  cross-review.sh status <session-dir>
      Print per-status counts (by each finding's final status, not raw
      line matches) plus a listing of open and disputed findings.

Env:
  CROSS_REVIEW_HOME         override the sessions root (default: .cross-review)
  CROSS_REVIEW_AGY_TIMEOUT  agy --print-timeout per review (default: 900s)
  CROSS_REVIEW_EXTRA_SENSITIVE  extra space-separated basename globs whose
                            content is kept out of the diff sent to reviewers
  CROSS_REVIEW_AGY_ALLOW_RULES_OK=1
                            run agy even if its settings have
                            permissions.allow rules (refused by default)
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

stored_repo_root() {
  local dir="$1"
  [[ -f "$dir/repo-root" ]] && cat "$dir/repo-root" || true
}

# A lock *file* (not directory) created under `set -C` (noclobber): the
# `>` redirect fails atomically if the file already exists, so creation
# and writing the owner pid happen as a single indivisible operation —
# no separate "create, then write pid" step, so no window where a lock
# exists but its pid file doesn't (an earlier mkdir-then-write version
# had exactly that gap). An EXIT trap (not RETURN — that fires on every
# function return, not just process exit) releases it however the
# script ends: success, error under set -e, or signal. The trap calls a
# named function rather than an interpolated string — session-dir is
# caller-controlled, and a path containing a single quote could
# otherwise break out of the trap's quoting and inject shell commands.
CROSS_REVIEW_LOCKFILE=""

release_lock() {
  [[ -n "$CROSS_REVIEW_LOCKFILE" ]] && rm -f -- "$CROSS_REVIEW_LOCKFILE" 2>/dev/null
  return 0
}

# The agy leg's scratch dir (and its out/err temp files), removed by an
# EXIT trap so an interrupted review (Ctrl-C, SIGTERM, an error under
# set -e) doesn't leave it behind — which matters most in the allow-rules
# override case, where the reviewer may have written into it. Same
# named-function-not-interpolated-string reasoning as release_lock.
CROSS_REVIEW_AGY_SCRATCH=""
CROSS_REVIEW_AGY_OUT=""
CROSS_REVIEW_AGY_ERR=""
CROSS_REVIEW_AGY_TRAP_SUBSHELL=""

cleanup_agy_tmp() {
  local p
  for p in "$CROSS_REVIEW_AGY_SCRATCH" "$CROSS_REVIEW_AGY_OUT" "$CROSS_REVIEW_AGY_ERR"; do
    [[ -n "$p" ]] && rm -rf -- "$p" 2>/dev/null
  done
  CROSS_REVIEW_AGY_SCRATCH="" CROSS_REVIEW_AGY_OUT="" CROSS_REVIEW_AGY_ERR=""
  # run_tool normally runs inside cmd_review's $(...) subshell, where this
  # trap replaces nothing — but the parent still holds the lock there and
  # is about to write findings.md, so only release it when this trap is
  # standing in for release_lock in the main shell. Uses the value saved
  # when the trap was installed, NOT $BASH_SUBSHELL here: bash 3.2 reports
  # 0 inside a $(...) child's EXIT trap even though the body saw 1
  # (verified), which would release the parent's lock early.
  [[ "$CROSS_REVIEW_AGY_TRAP_SUBSHELL" == "0" ]] && release_lock
  return 0
}

acquire_lock() {
  local dir="$1" waited=0 tmp_pid
  CROSS_REVIEW_LOCKFILE="$dir/.lock"
  while true; do
    # `ln` fails with EEXIST if the target already exists (unlike mv/
    # rename, which would silently replace it) — write the pid to a
    # uniquely-named temp file first, fully, then publish it under the
    # shared lock name with one atomic ln. Unlike `set -C > file` (the
    # prior approach), there's no window where the file is visible under
    # its final name before its content exists, since the content is
    # already complete before the name is ever shared.
    tmp_pid="$(mktemp "$dir/.lock.XXXXXX")"
    echo "$$" > "$tmp_pid"
    if ln "$tmp_pid" "$CROSS_REVIEW_LOCKFILE" 2>/dev/null; then
      rm -f "$tmp_pid"
      break
    fi
    rm -f "$tmp_pid"
    # A process killed with SIGKILL (or otherwise terminated abnormally)
    # never runs its EXIT trap, leaving the lock file behind forever with
    # no owner left to release it. Detect that by checking whether the
    # recorded owner pid is still alive — if it isn't, this is a dead
    # lock, not an active one, so reclaim it instead of waiting out (and
    # eventually failing on) a lock nobody is going to release. A missing
    # or empty pid file is treated as "can't tell, assume live" rather
    # than reclaimed: wrongly waiting is recoverable, wrongly reclaiming
    # an active lock isn't.
    local owner_pid
    owner_pid="$(cat "$CROSS_REVIEW_LOCKFILE" 2>/dev/null || true)"
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      echo "Reclaiming lock at $CROSS_REVIEW_LOCKFILE: owner pid $owner_pid is no longer running" >&2
      rm -f -- "$CROSS_REVIEW_LOCKFILE" 2>/dev/null
      continue
    fi
    if (( waited >= 30 )); then
      echo "Could not acquire lock on $dir after 30s (stale lock at $CROSS_REVIEW_LOCKFILE?)" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  trap release_lock EXIT
}

# Writes $tmp's content to stdout verbatim, unless it exceeds
# CROSS_REVIEW_MAX_FILE_DIFF_BYTES, in which case a one-line stub (still opening with a real
# `diff --git` header, so it reads like the real thing was just elided, not like the file was
# silently dropped) replaces it. Takes a temp-file path rather than a diff string in a bash
# variable — a multi-megabyte value doesn't need to round-trip through bash's own string
# handling just to be measured and conditionally emitted.
emit_file_diff() {
  local tmp="$1" path="$2" bytes lines
  bytes="$(wc -c < "$tmp" | tr -d ' ')"
  if (( bytes > CROSS_REVIEW_MAX_FILE_DIFF_BYTES )); then
    lines="$(wc -l < "$tmp" | tr -d ' ')"
    echo "diff --git a/$path b/$path"
    echo "@@ cross-review: diff omitted -- ${bytes} bytes / ${lines} lines, over the ${CROSS_REVIEW_MAX_FILE_DIFF_BYTES}-byte per-file cap (set CROSS_REVIEW_MAX_FILE_DIFF_BYTES to raise it). Large data fixtures / minified blobs have no reviewable line structure anyway -- inspect this file directly if its content matters here. @@"
  else
    cat "$tmp"
  fi
}

# True if $1's basename matches a sensitive-file glob (see CROSS_REVIEW_SENSITIVE_PATTERNS).
is_sensitive_path() {
  local name pat
  name="$(basename "$1")"
  case "$name" in
    *.example|*.sample|*.template|*.dist|*.pub) return 1 ;;
  esac
  # Unquoted $pat in the case pattern so it's matched as a glob; set -f keeps the unquoted
  # word list from being expanded against the cwd while it's split.
  set -f
  for pat in $CROSS_REVIEW_SENSITIVE_PATTERNS ${CROSS_REVIEW_EXTRA_SENSITIVE:-}; do
    case "$name" in
      $pat) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

# Prints "<blob-hash> <path>" for every non-empty sensitive-named file in the working tree --
# tracked, untracked, *and* gitignored (a gitignored .env is the usual source of a
# `cp .env somewhere-innocuous`). freeze_diff compares each changed file's hash against these
# to catch exact copies under a non-sensitive name, which no filename check or rename detection
# can see. Listing is done by git with glob pathspecs built from the same patterns, so the walk
# stays in C instead of a bash loop over every file in the repo; is_sensitive_path then drops
# templates. Only exact copies are caught -- an edited or partial copy still goes through.
sensitive_content_hashes() {
  local pat f
  local specs=()
  set -f
  for pat in $CROSS_REVIEW_SENSITIVE_PATTERNS ${CROSS_REVIEW_EXTRA_SENSITIVE:-}; do
    specs+=(":(glob)**/$pat")
  done
  set +f
  # -o without --exclude-standard includes ignored files, deliberately.
  git ls-files -c -o -z -- "${specs[@]}" | while IFS= read -r -d '' f; do
    [[ -f "$f" && -s "$f" ]] || continue
    is_sensitive_path "$f" || continue
    printf '%s %s\n' "$(git hash-object -- "$f")" "$f"
  done
}

# If blob hash $1 appears in $2 (sensitive_content_hashes output), print the matching file's
# path and return 0.
sensitive_hash_source() {
  local h="$1" hashes="$2"
  [[ -n "$h" && -n "$hashes" ]] || return 1
  printf '%s\n' "$hashes" | awk -v h="$h" '$1 == h { sub(/^[^ ]+ /, ""); print; found = 1; exit } END { exit !found }'
}

# If working-tree file $1 is byte-identical to a sensitive file, print that file's path.
sensitive_copy_source() {
  local f="$1" hashes="$2"
  [[ -n "$hashes" && -f "$f" && -s "$f" ]] || return 1
  sensitive_hash_source "$(git hash-object -- "$f")" "$hashes"
}

# Same, for the version of $2 at commit $1 -- a modified or deleted file's diff prints its old
# content as `-` lines, so a committed copy of a secret leaks on deletion even though nothing
# is left on disk to hash. Uses the blob id git already has; no-op if $2 didn't exist at $1.
sensitive_base_source() {
  local base="$1" f="$2" hashes="$3" h
  [[ -n "$hashes" ]] || return 1
  h="$(git rev-parse -q --verify "$base:$f" 2>/dev/null)" || return 1
  sensitive_hash_source "$h" "$hashes"
}

# Stub written in place of a sensitive file's diff -- still a real `diff --git` header so the
# reviewer can see the file changed, just not its content. detail, if given, says why a file
# with an innocuous name was stubbed (e.g. "renamed from .env").
emit_sensitive_stub() {
  local path="$1" detail="${2:-}"
  echo "Warning: $path${detail:+ ($detail)} matches a sensitive-file pattern; its content was left out of diff.patch (not sent to the reviewer)." >&2
  echo "diff --git a/$path b/$path"
  echo "@@ cross-review: diff omitted -- filename matches a sensitive-file pattern (credentials/keys/env), so its content was not sent to the reviewer. Add CROSS_REVIEW_EXTRA_SENSITIVE globs to extend the list. @@"
}

freeze_diff() {
  local dir="$1" base="${2:-HEAD}"
  local abs_dir abs_sessions_root
  abs_dir="$(cd -P "$dir" && pwd -P)"
  # Derived from abs_dir (dirname of "<sessions_root>/<timestamp>-<slug>")
  # rather than re-resolving $SESSIONS_ROOT from scratch — the latter is
  # just a relative name and would be exposed to the same cwd-relative-to-
  # where-init-ran ambiguity that the repo-root fix (F11) had to work
  # around for the session dir itself.
  abs_sessions_root="$(dirname "$abs_dir")"
  # A sessions root that resolves to the repo root itself would make the
  # exclusion below (rightly) skip "everything under the sessions root"
  # and (wrongly) skip every untracked file in the whole repo, silently
  # undoing the untracked-files fix entirely. There's no legitimate
  # reason to point CROSS_REVIEW_HOME at the repo root, so refuse rather
  # than degrade quietly.
  local repo_top
  repo_top="$(git rev-parse --show-toplevel)"
  if [[ "$abs_sessions_root" == "$repo_top" ]]; then
    echo "Sessions root ($abs_sessions_root) is the repository root — refusing, this would hide every untracked file in the repo from review, not just session scratch files. Point CROSS_REVIEW_HOME at a subdirectory instead." >&2
    exit 1
  fi
  {
    # One file at a time (not a single whole-tree `git diff "$base"`), so emit_file_diff can cap
    # each file independently — an oversized file no longer takes the rest of a perfectly
    # reviewable diff down with it (see emit_file_diff's own header for the real-world trigger).
    #
    # --name-status -M (not --name-only) so a rename's *source* path is visible too: `git mv .env
    # data.txt` or `git mv .env .env.example` lists only the innocuous new name otherwise, and
    # the per-path diff below then shows the old secret content as a brand-new file. -M is
    # explicit so this holds even with diff.renames=false in the user's config. With -z, each
    # entry is "<status>\0<path>\0", or "R<score>\0<src>\0<dst>\0" for renames. Copies aren't
    # detected here (-C only considers modified files as sources; --find-copies-harder costs a
    # scan of every tracked file per round) -- the content-hash check below covers those.
    local f tmp st src copied_from sens_hashes
    sens_hashes="$(sensitive_content_hashes)"
    git diff --name-status -M -z "$base" | while IFS= read -r -d '' st; do
      src=""
      case "$st" in
        R*|C*) IFS= read -r -d '' src; IFS= read -r -d '' f ;;
        *) IFS= read -r -d '' f ;;
      esac
      if is_sensitive_path "$f"; then emit_sensitive_stub "$f"; continue; fi
      if [[ -n "$src" ]] && is_sensitive_path "$src"; then
        emit_sensitive_stub "$f" "renamed from $src"
        continue
      fi
      if copied_from="$(sensitive_copy_source "$f" "$sens_hashes")"; then
        emit_sensitive_stub "$f" "same content as $copied_from"
        continue
      fi
      # Old side only exists for non-added, non-renamed entries (a rename's per-path diff below
      # shows only the new content).
      case "$st" in
        A*|R*|C*) ;;
        *)
          if copied_from="$(sensitive_base_source "$base" "$f" "$sens_hashes")"; then
            emit_sensitive_stub "$f" "previous version had the same content as $copied_from"
            continue
          fi
          ;;
      esac
      tmp="$(mktemp)"
      git diff "$base" -- "$f" > "$tmp"
      emit_file_diff "$tmp" "$f"
      rm -f "$tmp"
    done
    # git diff never includes untracked files (verified: a staged new
    # file shows up fine, a genuinely untracked one is invisible), so a
    # change consisting of brand-new files would otherwise vanish from
    # review entirely. Synthesize an "added file" diff for each one
    # against /dev/null instead. --no-index exits 1 whenever it finds a
    # difference (which a new file always does), so guard it explicitly
    # rather than let `set -e` treat that as this function failing.
    #
    # Exclude the whole sessions root (not just this session's own dir)
    # by resolved absolute path, not by name prefix — if the target repo
    # doesn't gitignore .cross-review (or CROSS_REVIEW_HOME points
    # elsewhere, or init ran from a subdirectory), other sessions' own
    # task.md/base/diff.patch would otherwise show up as "untracked
    # files" too and get folded into an unrelated review's diff.
    git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
      case "$(cd -P "$(dirname "$f")" && pwd -P)/$(basename "$f")" in
        "$abs_sessions_root"/*) continue ;;
      esac
      if is_sensitive_path "$f"; then emit_sensitive_stub "$f"; continue; fi
      if copied_from="$(sensitive_copy_source "$f" "$sens_hashes")"; then
        emit_sensitive_stub "$f" "same content as $copied_from"
        continue
      fi
      tmp="$(mktemp)"
      git diff --no-index -- /dev/null "$f" > "$tmp" || true
      emit_file_diff "$tmp" "$f"
      rm -f "$tmp"
    done
  } > "$dir/diff.patch"
  # Whole-diff safety net, after per-file capping above -- see
  # CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES's own comment on why this warns instead of failing.
  local total_bytes
  total_bytes="$(wc -c < "$dir/diff.patch" | tr -d ' ')"
  if (( total_bytes > CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES )); then
    echo "Warning: $dir/diff.patch is ${total_bytes} bytes, over the ${CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES}-byte total-diff threshold (CROSS_REVIEW_MAX_TOTAL_DIFF_BYTES) even after per-file capping (CROSS_REVIEW_MAX_FILE_DIFF_BYTES=${CROSS_REVIEW_MAX_FILE_DIFF_BYTES}). A reviewer CLI's own input cap may still reject this -- consider a lower CROSS_REVIEW_MAX_FILE_DIFF_BYTES or splitting this into more than one review session." >&2
  fi
}

# mode is "review" (must not write to the repo) or "author" (needs write
# access to actually fix things). token_file, if given, gets the tool's
# reported token usage for this call written to it ("unknown" if the
# tool doesn't expose one) — kept out of stdout since stdout here becomes
# the finding/response text itself. model, if given, pins which
# underlying model the tool uses instead of its default — e.g. to have
# the same vendor's CLI review with a different model than whatever
# wrote the code (see README for why that's weaker than cross-vendor
# review but still better than nothing).
run_tool() {
  local tool="$1" mode="$2" prompt_file="$3" token_file="${4:-}" model="${5:-}"
  case "$tool" in
    codex)
      # Verified against real codex-cli 0.153.2: prompt piped via stdin
      # (avoids ARG_MAX issues with large diffs), sandbox enforces the
      # read-only guarantee at the tool level instead of relying on the
      # prompt alone, -o gives us just the final message instead of the
      # full event transcript.
      local sandbox="read-only"
      [[ "$mode" == "author" ]] && sandbox="workspace-write"
      local out transcript rc=0
      out="$(mktemp)"
      transcript="$(mktemp)"
      # Plain if/else rather than an args array: bash 3.2 (macOS's default
      # /bin/bash, which this whole script targets) treats "${arr[@]}" on
      # a declared-but-empty array as unbound under set -u.
      if [[ -n "$model" ]]; then
        codex exec --sandbox "$sandbox" -m "$model" -o "$out" - < "$prompt_file" > "$transcript" 2>&1 || rc=$?
      else
        codex exec --sandbox "$sandbox" -o "$out" - < "$prompt_file" > "$transcript" 2>&1 || rc=$?
      fi
      if (( rc != 0 )); then
        # mktemp pre-creates $out as an empty file, so a failed codex exec
        # (e.g. an invalid --model) still leaves a readable-but-empty file
        # behind — `cat "$out"` would exit 0 with no output, silently
        # turning a real failure into what looks like an empty-findings
        # round instead of surfacing the error.
        echo "codex exec failed (exit $rc):" >&2
        cat "$transcript" >&2
        rm -f "$out" "$transcript"
        exit 1
      fi
      cat "$out"
      if [[ -n "$token_file" ]]; then
        # Human-readable transcript ends with a literal "tokens used"
        # line followed by a comma-formatted number on the next line
        # (verified against codex-cli 0.153.2's actual output) — no
        # --json/structured field for this was in the CLI's help output,
        # so this is a best-effort scrape that could break on a future
        # codex-cli version, not a documented contract.
        awk '/^tokens used$/{getline; gsub(/,/,""); print; found=1; exit} END{if (!found) print "unknown"}' "$transcript" > "$token_file"
      fi
      rm -f "$out" "$transcript"
      ;;
    agy)
      # Verified against real agy 1.3.0. Headless (-p) mode auto-denies
      # every tool call — shell commands, file reads, file writes — and
      # neither --mode plan nor --mode accept-edits changes that. A denied
      # call doesn't fail the run: agy exits 0 with an empty response and
      # a notice on stderr. So this leg is prompt-only: the reviewer gets
      # everything inline and is told up front not to reach for tools.
      # That auto-deny is also the read-only guarantee (codex's
      # --sandbox read-only equivalent) — unless your agy settings.json
      # adds permissions.allow rules, which would apply here too.
      # Deliberately not --mode plan: it injects a /plan directive telling
      # the model to write an implementation-plan artifact first, which a
      # headless run can only have denied (verified by asking agy 1.3.0
      # about its own system prompt with and without the flag).
      if [[ "$mode" == "author" ]]; then
        echo "agy can't run as author headlessly: agy -p auto-denies file writes (write_file) even with --mode accept-edits. Respond interactively instead, or use --with codex|claude." >&2
        exit 1
      fi
      command -v jq >/dev/null || { echo "agy leg needs jq to parse agy's JSON output" >&2; exit 1; }
      # The auto-deny above is the only thing keeping review read-only, and
      # allow-grants switch it off for whatever they match — headless runs
      # included (--dangerously-skip-permissions doesn't; it's ignored under
      # -p). So refuse when any local file agy takes grants from has one,
      # rather than trust the prompt to keep an allowed tool unused. Sources
      # found in the agy 1.3.0 binary: permissions.allow in the user and
      # admin settings files, globalPermissionGrants in the shared
      # ~/.gemini/config/config.json, and per-project grants in the project
      # records under ~/.gemini/config/projects/ (ApplyProjectPermissionGrants).
      # The check covers only the grant containers confirmed there, by exact
      # key: top-level `permissions` (named in agy's own denial message),
      # and `globalPermissionGrants` / `permissionGrants` at any depth
      # (protobuf JSON names in the binary; the "%d allow, %d deny grants"
      # log line confirms their allow/deny shape). Each one present must be
      # an object (or null) whose `allow` is absent or an empty array.
      # Deliberately exact-key, not a "permission" substring match: agy also
      # writes harmless flags like permissionGrantsV2Migrated: true, and
      # refusing on those broke migrated configs. Other permission-like
      # fields (allowedTools, allowlist, ...) aren't checked, since nothing
      # shows they grant headless tool use — and server-side grants
      # (AddPermissionGrants, GetUserAccountSettings RPCs) are invisible
      # here regardless. So this is best effort; the read-only guarantee
      # rests on the headless auto-deny and the prompt-only design.
      # Repo-level config never applies: agy runs from an empty scratch dir
      # (below). CROSS_REVIEW_AGY_ALLOW_RULES_OK=1 overrides, for grants
      # you've checked can't write (e.g. read-only commands).
      # Exactly "1", not just non-empty — "0"/"false" must not switch the
      # check off.
      if [[ "${CROSS_REVIEW_AGY_ALLOW_RULES_OK:-}" != "1" ]]; then
        local sf
        for sf in "$HOME/.gemini/antigravity-cli/settings.json" \
                  "$HOME/.gemini/config/config.json" \
                  "/Library/Application Support/Antigravity/admin_settings.json" \
                  "/etc/antigravity/admin_settings.json" \
                  "$HOME"/.gemini/config/projects/*.json; do
          # Skips missing files, and the literal pattern bash leaves behind
          # when the projects glob matches nothing.
          [[ -e "$sf" ]] || continue
          # One slurped (-s) jq call decides everything, failing closed:
          #   - empty / whitespace-only file: slurps to [] -> passes (agy
          #     ships an empty mcp_config.json the same way)
          #   - unreadable, invalid JSON, or several top-level values (jq -e
          #     alone only looks at the last one): fails -> refuse
          #   - shape asserted rather than grants tested for: a positive
          #     "has grants" test fails open on a jq type error (e.g.
          #     "allow": true exits 5, which `if` reads as "no grants")
          if ! jq -se 'length <= 1
                       and ((.[0] // {}) | type == "object"
                            and ([.permissions, (.. | objects | .globalPermissionGrants?, .permissionGrants?)]
                                 | map(select(. != null))
                                 | all(type == "object"
                                       and ((.allow // []) | type == "array" and length == 0))))' "$sf" >/dev/null 2>&1; then
            echo "Refusing to run agy as reviewer: $sf has permission allow-grants, or couldn't be read or parsed to check (grants apply to headless agy too and would let the reviewer use those tools against your machine). Remove them, or set CROSS_REVIEW_AGY_ALLOW_RULES_OK=1 if you've confirmed none of them can write." >&2
            exit 1
          fi
        done
      fi
      # No stdin support (-p requires an argument; `-p -` takes "-" as the
      # literal prompt), so the prompt goes in as one argv string. That's
      # bounded by ARG_MAX (1MB on macOS, environment included); a prompt
      # past it fails at exec with a non-zero exit, caught below.
      local prompt out errf scratch rc=0
      prompt="IMPORTANT for this run: you have no tool access. Every shell command, file read, and file write will be automatically denied, and a denied tool call ends the run with no output at all. Everything you need — task, full diff, and findings ledger — is included below. Do not try to read files or run commands; review from this text only.

$(cat "$prompt_file")"
      out="$(mktemp)"
      errf="$(mktemp)"
      CROSS_REVIEW_AGY_OUT="$out"
      CROSS_REVIEW_AGY_ERR="$errf"
      CROSS_REVIEW_AGY_TRAP_SUBSHELL="$BASH_SUBSHELL"
      trap cleanup_agy_tmp EXIT
      # Run from an empty scratch dir, not the repo under review. The leg is
      # prompt-only, so agy never needs the repo as its workspace — and
      # launching it there would hand agy that repo's own project config
      # (.agents/hooks.json, .agents/skills, workflows, GEMINI.md/AGENTS.md
      # rules), which a diff under review could have added or changed. It
      # also means a tool call that slips through via permissions.allow
      # rules lands relative paths in throwaway space instead of the repo
      # (absolute paths still could reach it — see the refusal check above).
      scratch="$(mktemp -d)"
      CROSS_REVIEW_AGY_SCRATCH="$scratch"
      # mktemp honours TMPDIR, which could point inside the repo — then the
      # "empty" dir would sit under the repo after all, and agy could pick
      # up the repo's config from an ancestor dir. Fail closed. cmd_review
      # has already cd'd to the repo root, so $(pwd -P) is it.
      local abs_scratch repo_abs
      abs_scratch="$(cd -P "$scratch" && pwd -P)"
      repo_abs="$(pwd -P)"
      case "$abs_scratch/" in
        "$repo_abs"/*)
          echo "Refusing to run agy: its scratch dir ($abs_scratch) is inside the repo under review ($repo_abs) — point TMPDIR outside the repo." >&2
          rm -rf "$scratch" "$out" "$errf"
          exit 1
          ;;
      esac
      # --print= with the value attached: agy's flag parser otherwise takes
      # whatever argument follows -p as the prompt, so a misplaced flag
      # would silently become the prompt instead. If/else rather than an
      # args array for the same bash 3.2 empty-array reason as the codex leg.
      #
      # --sandbox ("terminal restrictions", per agy --help) is an extra,
      # UNVERIFIED layer for the override case: whether it actually blocks
      # writes couldn't be tested, because nothing short of a real
      # permissions.allow rule lets headless agy use a tool at all —
      # --dangerously-skip-permissions is ignored under -p (verified: a
      # shell write was still auto-denied with it, with and without
      # --sandbox). It's confirmed harmless for a normal run. Don't count it
      # as the read-only guarantee; the auto-deny plus the refusal check
      # above is that.
      #
      # cd -P into the resolved path that was just checked, not $scratch: a
      # logical cd through a symlinked TMPDIR inside the repo would leave
      # $PWD pointing into the repo, which agy (Go's os.Getwd honours a
      # matching $PWD) could then use for ancestor config discovery.
      if [[ -n "$model" ]]; then
        ( cd -P "$abs_scratch" && agy --sandbox --print-timeout "${CROSS_REVIEW_AGY_TIMEOUT:-900s}" --output-format json --model "$model" --print="$prompt" ) > "$out" 2> "$errf" || rc=$?
      else
        ( cd -P "$abs_scratch" && agy --sandbox --print-timeout "${CROSS_REVIEW_AGY_TIMEOUT:-900s}" --output-format json --print="$prompt" ) > "$out" 2> "$errf" || rc=$?
      fi
      rm -rf "$scratch"
      # agy exits 0 for several runs that produced nothing usable, so the
      # exit code alone can't be trusted. Observed failure shapes:
      #   - non-zero exit (e.g. account eligibility/licensing errors)
      #   - status other than SUCCESS
      #   - empty response + denied_actions (reviewer tried a tool anyway)
      #   - empty response + total_tokens 0 ("run ended with no output and
      #     no recorded error" — seen with pathological inputs)
      #   - --print-timeout hit: still exit 0 + SUCCESS, with only a stderr
      #     line ("[agy] print timeout after <n> with turn in progress;
      #     returning partial output") to say so — and that partial output
      #     can be non-empty, i.e. truncated findings that look complete
      # So any blank response is treated as a failure, whatever else the
      # JSON says. That's safe because agy won't send a truly empty reply
      # even when asked to, so a genuine no-findings round still has text.
      # The timeout check matches agy 1.3.0's stderr wording — a scrape,
      # not a contract, like codex's token parsing.
      local timed_out=""
      grep -q 'print timeout after' "$errf" 2>/dev/null && timed_out="yes"
      local status="" response="" denied="" total=0
      if (( rc == 0 )); then
        status="$(jq -r '.status // empty' "$out" 2>/dev/null || true)"
        response="$(jq -r '.response // empty' "$out" 2>/dev/null || true)"
        denied="$(jq -r '[.denied_actions[]?.action] | join(",")' "$out" 2>/dev/null || true)"
        total="$(jq -r '.usage.total_tokens // 0' "$out" 2>/dev/null || echo 0)"
      fi
      if (( rc != 0 )) || [[ -n "$timed_out" ]] || [[ "$status" != "SUCCESS" ]] || [[ -z "${response//[[:space:]]/}" ]]; then
        echo "agy failed (exit $rc, status ${status:-none}, denied: ${denied:-none}, tokens: ${total:-0}${timed_out:+, timed out — raise CROSS_REVIEW_AGY_TIMEOUT}):" >&2
        cat "$errf" >&2
        cat "$out" >&2
        rm -f "$out" "$errf"
        exit 1
      fi
      if [[ -n "$denied" ]]; then
        echo "Note: agy attempted tool calls that were denied ($denied); its response was still recorded." >&2
      fi
      printf '%s\n' "$response"
      [[ -n "$token_file" ]] && echo "$total" > "$token_file"
      rm -f "$out" "$errf"
      ;;
    claude)
      # If this hangs for minutes with no output, it's almost certainly
      # an invalid ANTHROPIC_API_KEY env var (claude -p retries 401s 11x
      # with backoff before surfacing anything) — not this harness. See
      # README "Status per tool".
      #
      # Token tracking not implemented yet: --output-format json reports
      # usage, but this wasn't verified in-session (this session's own
      # process has a stale ANTHROPIC_API_KEY baked into its env from
      # before the fix, so testing claude -p here would hit the same
      # 401-retry hang documented above — needs verifying from a fresh
      # terminal, same as the rest of the claude leg was).
      local perm="plan"
      [[ "$mode" == "author" ]] && perm="acceptEdits"
      # Captured and exit-checked explicitly: run_tool runs inside $(...),
      # and bash 3.2 doesn't carry set -e into command substitutions, so a
      # failed claude call would otherwise fall through to the next line
      # and get recorded as an empty-findings round.
      local out errf rc=0
      out="$(mktemp)"
      errf="$(mktemp)"
      if [[ -n "$model" ]]; then
        claude -p --permission-mode "$perm" --output-format text --model "$model" < "$prompt_file" > "$out" 2> "$errf" || rc=$?
      else
        claude -p --permission-mode "$perm" --output-format text < "$prompt_file" > "$out" 2> "$errf" || rc=$?
      fi
      if (( rc != 0 )); then
        echo "claude -p failed (exit $rc):" >&2
        cat "$errf" "$out" >&2
        rm -f "$out" "$errf"
        exit 1
      fi
      cat "$errf" >&2
      cat "$out"
      rm -f "$out" "$errf"
      [[ -n "$token_file" ]] && echo "unknown" > "$token_file"
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

  # Record the repo root so later review/respond calls operate there
  # regardless of the caller's cwd when they invoke this — otherwise
  # running `respond` from a different directory than `init` was run in
  # could freeze diffs or (worse) let the author tool edit files against
  # the wrong repo entirely while still correctly appending to this
  # session's ledger.
  git rev-parse --show-toplevel > "$dir/repo-root"

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
  dir="$(cd -P "$dir" && pwd -P)"
  local tool="" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with) tool="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$tool" ]] || { echo "--with codex|agy|claude is required" >&2; exit 1; }

  acquire_lock "$dir"

  # Operate from the repo root recorded at init time, not wherever the
  # caller happens to be now — otherwise running review/respond from a
  # different cwd than init used could diff (or, worse, edit) the wrong
  # repo while still appending to the right session's ledger. Falls back
  # to the caller's cwd for sessions created before this was recorded.
  local repo_root
  repo_root="$(stored_repo_root "$dir")"
  [[ -n "$repo_root" ]] && cd -P "$repo_root"

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

  local token_file
  token_file="$(mktemp)"
  local output
  output="$(run_tool "$tool" review "$prompt_file" "$token_file" "$model")"
  local tokens
  tokens="$(cat "$token_file")"
  rm -f "$prompt_file" "$token_file"

  # A reviewer that ignores the output format (e.g. replies with a prose summary of what it
  # "reported") would otherwise be recorded as a round with no findings -- `status` then shows
  # nothing open while a real finding exists only as prose. Require at least one `## F<n>` entry
  # or the explicit no-findings line; otherwise keep the raw reply next to the ledger, but out
  # of it, and fail.
  if ! printf '%s\n' "$output" | grep -qE '^(## F[0-9]+ |No new findings)'; then
    local rejected="$dir/round-$round-rejected.md"
    printf '%s\n' "$output" > "$rejected"
    echo "Reviewer output for round $round has no '## F<n>' findings and no 'No new findings' line, so it wasn't appended to findings.md. Raw output saved to $rejected -- re-run the review, or transcribe any findings by hand." >&2
    exit 1
  fi

  {
    echo
    echo "## Round $round — reviewer:$tool${model:+ ($model)} — $(date -u +%FT%TZ) — tokens: $tokens"
    echo
    echo "$output"
  } >> "$dir/findings.md"

  echo "Appended round $round ($tool${model:+ model:$model}) to $dir/findings.md"
}

cmd_respond() {
  local dir="${1:?session dir required}"; shift
  dir="$(cd -P "$dir" && pwd -P)"
  local tool="" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with) tool="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
  [[ -n "$tool" ]] || { echo "--with codex|claude is required" >&2; exit 1; }

  acquire_lock "$dir"

  local repo_root
  repo_root="$(stored_repo_root "$dir")"
  [[ -n "$repo_root" ]] && cd -P "$repo_root"

  freeze_diff "$dir" "$(stored_base "$dir")"
  local round
  round="$(next_round "$dir/findings.md")"

  local prompt_file
  prompt_file="$(mktemp)"

  {
    cat "$ROOT_DIR/prompts/respond.md"
    echo
    echo "## Session"
    echo "Working directory: $(pwd)"
    echo "Findings ledger (append your Response blocks here): $dir/findings.md"
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
  local token_file
  token_file="$(mktemp)"
  run_tool "$tool" author "$prompt_file" "$token_file" "$model"
  local tokens
  tokens="$(cat "$token_file")"
  rm -f "$prompt_file" "$token_file"

  echo
  echo "tokens: $tokens"
  echo "Ran $tool${model:+ (model:$model)} as author over $dir/findings.md — review its edits and"
  echo "confirm it appended Response blocks before the next review round."
}

# Parses findings.md into one tab-separated row per finding:
#   id \t final_status \t severity \t file \t summary \t responded
# "final_status" is whichever Status: line occurs LAST inside that
# finding's block, so a finding that started open and later got a
# "### Response (author)" with Status: fixed is counted once, as fixed —
# not once for each line (a naive grep -c per status double-counts these).
# "responded" is 1 if the finding has any "### Response (author)" block, so
# a finding the author deliberately left open (e.g. a security call that
# needs human sign-off) can be told apart from one nobody has answered.
parse_findings() {
  local findings="$1"
  awk '
    function emit() {
      if (fid != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%d\n", fid, status, severity, file, summary, responded
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
      responded = 0
      next
    }
    fid != "" && /^### Response \(author\)/ {
      responded = 1
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

  # Round headers look like "## Round N — reviewer:tool — <ts> — tokens: V"
  # (V is a digit count from run_tool, or "unknown" for tools/paths that
  # don't report one yet — see run_tool's per-tool notes). Computed before
  # the findings check below since a round can legitimately find nothing,
  # and token usage shouldn't disappear from the report just because it
  # didn't.
  local token_summary
  token_summary="$(awk -F'tokens: ' '
    /^## Round / {
      v = $2
      # v is empty (not "unknown") for rounds recorded before the
      # tokens: field existed at all — those must not silently count as
      # "known, contributed 0" or both the round count and the resulting
      # average get quietly wrong.
      if (v == "unknown" || v == "") { unknown++ } else { sum += v; known++ }
    }
    END { printf "%d\t%d\t%d", sum+0, known+0, unknown+0 }
  ' "$dir/findings.md")"
  local tok_sum tok_known tok_unknown
  IFS=$'\t' read -r tok_sum tok_known tok_unknown <<< "$token_summary"

  local rows
  rows="$(parse_findings "$dir/findings.md")"

  if [[ -z "$rows" ]]; then
    echo "No findings yet."
    if (( tok_known + tok_unknown > 0 )); then
      if (( tok_unknown > 0 )); then
        echo "Tokens: $tok_sum across $tok_known round(s) ($tok_unknown round(s) unknown — tool doesn't report usage yet)"
      else
        echo "Tokens: $tok_sum across $tok_known round(s)"
      fi
    fi
    return
  fi

  local total open fixed wontfix disputed
  total="$(echo "$rows" | wc -l | tr -d ' ')"
  open="$(echo "$rows" | awk -F'\t' '$2=="open"' | wc -l | tr -d ' ')"
  fixed="$(echo "$rows" | awk -F'\t' '$2=="fixed"' | wc -l | tr -d ' ')"
  wontfix="$(echo "$rows" | awk -F'\t' '$2=="wontfix"' | wc -l | tr -d ' ')"
  disputed="$(echo "$rows" | awk -F'\t' '$2=="disputed"' | wc -l | tr -d ' ')"

  echo "$total findings — open=$open fixed=$fixed wontfix=$wontfix disputed=$disputed"

  if (( tok_known + tok_unknown > 0 )); then
    if (( tok_unknown > 0 )); then
      echo "Tokens: $tok_sum across $tok_known round(s) ($tok_unknown round(s) unknown — tool doesn't report usage yet)"
    else
      echo "Tokens: $tok_sum across $tok_known round(s)"
    fi
  fi

  local open_rows
  open_rows="$(echo "$rows" | awk -F'\t' '$2=="open" && $6!="1"')"
  if [[ -n "$open_rows" ]]; then
    echo
    echo "Open (awaiting author response):"
    echo "$open_rows" | awk -F'\t' '{printf "  %s [%s] %s — %s\n", $1, $3, $5, $4}'
  fi

  local signoff_rows
  signoff_rows="$(echo "$rows" | awk -F'\t' '$2=="open" && $6=="1"')"
  if [[ -n "$signoff_rows" ]]; then
    echo
    echo "Open — needs human sign-off (author responded but left it open):"
    echo "$signoff_rows" | awk -F'\t' '{printf "  %s [%s] %s — %s\n", $1, $3, $5, $4}'
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
