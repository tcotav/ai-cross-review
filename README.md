# cross-review

A minimal cross-vendor review harness for Claude Code, Codex CLI, and
Antigravity (`agy`). One tool writes code; a *different* vendor's model
reviews it; findings and responses accumulate in a single markdown ledger
per session.

Why: a model reviewing its own output tends to rationalize — same priors,
same blind spots that produced the bug. A different vendor's model brings
different priors and different bug sensitivity.

This is deliberately thin. It does not manage specs, plans, or tasks, and it
does not loop automatically — you decide when to run another round.

## Requirements

- `git`
- At least two of: `claude` (Claude Code), `codex` (Codex CLI), `agy`
  (Antigravity CLI), each authenticated and on `PATH`.
- Optional: `skills/cross-review-brief` symlinked into `~/.claude/skills/`
  (see Install) to have Claude Code write `task.md` for you.

## Install

Symlink, don't copy — this keeps the repo as the single source of truth,
so `git pull` here updates everywhere it's linked.

```bash
ln -s "$(pwd)/cross-review.sh" ~/bin/cross-review.sh          # needs ~/bin on PATH
ln -s "$(pwd)/skills/cross-review-brief" ~/.claude/skills/cross-review-brief
```

`cross-review.sh` resolves its own real location through the symlink (to
find `prompts/`), so this works from any directory once `~/bin` is on
`PATH`.

## Usage

```bash
# 1. Start a session — freezes the current diff against HEAD.
./cross-review.sh init auth-rework
# -> .cross-review/20260905-0900-auth-rework

# 2. Fill in the task/spec — either by hand, or ask Claude Code to run the
#    cross-review-brief skill, which extracts the original ask from the
#    conversation instead of you (or it) writing a retrospective summary
#    of the work. Works regardless of when you decided to cross-review —
#    start, middle, or end of the task — since it's pulling a fixed fact
#    (what was asked) rather than judging the outcome.
$EDITOR .cross-review/20260905-0900-auth-rework/task.md

# 3. Get a review from a different vendor than whoever wrote the code.
./cross-review.sh review .cross-review/20260905-0900-auth-rework --with codex

# 4. Read findings.md yourself and fix what's real (recommended), or let a
#    tool attempt it headlessly:
./cross-review.sh respond .cross-review/20260905-0900-auth-rework --with claude

# 5. Re-review — the reviewer re-checks anything marked "fixed" against the
#    new diff instead of trusting the label.
./cross-review.sh review .cross-review/20260905-0900-auth-rework --with codex

# 6. Check where things stand.
./cross-review.sh status .cross-review/20260905-0900-auth-rework
```

`status` reports each finding's *final* status (a finding that started
`open` and later got a `Status: fixed` response counts once, as fixed —
not once per line), plus a listing of anything still open or disputed:

```
5 findings — open=2 fixed=1 wontfix=1 disputed=1

Open (awaiting author response):
  F4 [major] Unhandled exception on empty input — src/api.py:80
  F5 [critical] Race condition in cache write — src/cache.py:22

Disputed (author pushed back, reviewer should re-check):
  F3 [major] Off-by-one in pagination — src/api.py:55
```

`status` also sums token usage recorded in each round header (`## Round
N — reviewer:tool — <ts> — tokens: V`):

```
Tokens: 4672 across 2 round(s)
```

Currently only `codex` reports a real number (scraped from its
transcript — no `--json` field for this exists in `codex exec --help`,
so treat it as best-effort, not a guarantee across versions); `claude`
and `agy` report `unknown` until someone verifies their usage-reporting
path. `respond`'s token cost isn't summed into `status` — there's no
per-round ledger slot for it since the author tool writes its own
Response block content, not this script — but it prints at call time.

## The ledger

`findings.md` is the only shared state. Reviewers append `## F<n>` entries
under a `## Round N` header; the author appends `### Response (author)`
blocks under each one. Nobody rewrites anyone else's entry — only append.

Finding shape (borrowed from
[formin/multi-model-review](https://github.com/formin/multi-model-review),
which does this well even though its overall workflow — a Spec Kit
extension with one-shot package/report/apply, not an iterative ledger —
didn't fit what this needs):

```
## F1 — SQL injection risk in query builder
Reviewer: codex | Round: 1 | Severity: critical | Confidence: 90 | Status: open
File: src/db.py:142

User input is concatenated directly into the query string here; the diff's
new `search()` path doesn't go through the parameterized helper the rest of
the file uses.

Suggested fix: build the query with the existing `qb.param()` helper instead
of f-string interpolation.

### Response (author)
Status: fixed | Round: 2

Switched to qb.param(), see latest diff.
```

Severity: `critical | major | minor | info`.
Confidence: `0-100` — reviewers are told to report low confidence honestly
rather than inflate it.
Status: `open | fixed | wontfix | disputed`.

## Status per tool

- **`--with codex`** — verified against real `codex-cli 0.153.2`. `review`
  mode pipes the prompt over stdin and runs with `--sandbox read-only`, so
  the no-write guarantee is enforced by the tool, not just the prompt;
  `respond` mode switches to `--sandbox workspace-write`. Confirmed it
  correctly flags an injected SQL-injection bug end to end.
- **`--with claude`** — verified. `claude -p "..." --output-format text`
  returns in ~5s once auth is clean. `review` mode uses
  `--permission-mode plan` (read-only); `respond` uses `acceptEdits`. If
  it hangs for you, it's very likely not this harness: check
  `env | grep -i anthropic` for a stale `ANTHROPIC_API_KEY` — an invalid
  key makes `claude -p` retry 11x with exponential backoff before
  surfacing anything, which looks exactly like a multi-minute hang. Debug
  with `claude -p "..." --debug-file /tmp/claude-debug.log` and check the
  log tail for `authentication_error` if it recurs. Note the bad key can
  be inherited by a *parent* Claude Code process too — fixing your shell
  rc file won't fix an already-running session that already loaded it;
  restart the session.
- **`--with agy`** — untested, no Antigravity install available when this
  was written. Wired up per the documented headless flags
  (`agy -p "<prompt>" --output-format text`); no read-only/plan-mode
  equivalent to codex's `--sandbox read-only` applied yet — check for one
  before trusting it not to touch files.

## Other known rough edges

- `respond` runs the author role headlessly for scripting convenience.
  Actually fixing code usually goes better in your normal interactive
  session — read `findings.md` yourself and work the list.
- No support yet for local/OSS model backends (Codex `--oss`, etc.) — add
  a case in `run_tool()` if you need it.
