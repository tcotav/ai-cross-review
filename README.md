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

## Same vendor vs. cross-vendor

Every reviewer invocation is a fresh, standalone process — `run_tool`
never resumes or forks a prior session, and the prompt it's given is
self-contained (`task.md` + `diff.patch` + `findings.md` only). So
nothing stops you from reviewing with the *same* vendor or even the
same model that wrote the code (`--with codex --model <name>`, see
below), and it won't "remember" writing it — there's no shared session
to pull context from.

What it won't give you is protection from *correlated* blind spots.
Fresh-process isolation defeats "I remember writing this, so it's
fine" rationalization, but the same weights/training still tend to
miss the same classes of bugs regardless of whether the process has
memory of writing them. Cross-vendor review defends against both;
same-vendor (even with a different model via `--model`) only defends
against the first. Still better than a stateful self-review, just not
equivalent.

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
mkdir -p ~/bin ~/.claude/skills   # both commonly don't exist on a fresh machine
ln -s "$(pwd)/cross-review.sh" ~/bin/cross-review.sh          # needs ~/bin on PATH
ln -s "$(pwd)/skills/cross-review-brief" ~/.claude/skills/cross-review-brief
```

`cross-review.sh` resolves its own real location through the symlink (to
find `prompts/`), so this works from any directory once `~/bin` is on
`PATH`.

## Usage

There are two ways to drive this. Talking to Claude Code (or whatever
agent you're already working with) is the more common path in
practice — the CLI is what's actually running underneath, but you
rarely need to type it yourself.

### Via Claude Code (typical)

Just ask, once you've got a change you want a second opinion on:

> brief this for cross-review and get a codex review

Claude Code runs the `cross-review-brief` skill to write `task.md` from
what you actually asked for earlier in the conversation (not a
self-graded summary of the work — see the skill for why that
distinction matters), then drives `init` → `review` → reading
`findings.md` itself via the CLI commands below. It'll typically fix
real findings directly in the same session and loop `review` again to
confirm, reporting back a summary rather than you watching raw command
output. Say which tool to review with (`codex`, `claude`, `agy`) and
optionally `--model` if you want a specific one; if you don't say,
ask which vendor before assuming.

### Recommended order (and a pitfall to avoid)

**Don't commit before reviewing.** `init` with no `--base` diffs against
`HEAD` — if you've already committed your change, `HEAD` *is* that
change, so `git diff HEAD` shows nothing and you get an empty review.
Reviewing the uncommitted working tree is what works by default with
no extra flags; if you do want to review something already committed,
pass `--base <ref-before-it>` explicitly.

This also happens to be close to optimal for token cost and scan
radius:

1. Finish one focused unit of work — don't batch unrelated changes
   into one diff. Smaller diffs cost fewer reviewer tokens and are
   easier for the reviewer to actually hold in its head at once.
2. Ask for the brief right away, while the ask is still recent in
   conversation — cheaper for whoever's writing `task.md` than
   scanning back through a long session later.
3. `init` + `review` against the *uncommitted* tree.
4. Fix real findings directly rather than via headless `respond` — one
   less tool invocation for something you can just do in-session.
5. Re-review once to confirm. Every round resends the *entire*
   `findings.md` ledger in the prompt, so cost scales with round count
   on a given session, not just diff size — loop more only if you're
   genuinely still finding things, not by default.
6. Commit last, once the loop settles — one clean commit of reviewed
   code instead of a raw commit plus fixups.
7. Start a fresh session (`init`) for the next unit of work rather than
   reusing this one — keeps each ledger small instead of letting it
   accumulate across unrelated changes.

### Manual CLI

Useful for scripting, CI, or when you're not in an interactive agent
session at all.

```bash
# 1. Start a session — freezes the current diff against HEAD.
./cross-review.sh init auth-rework
# -> .cross-review/20260905-0900-auth-rework

# 2. Fill in the task/spec by hand (or use the skill above, even from a
#    manual flow — it just needs a Claude Code session to run in).
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

`review` and `respond` also take `--model <name>` to pin a specific
model instead of the tool's default — e.g. `--with codex --model
gpt-5.6-luna`. Useful for same-vendor review with a different model
than whatever wrote the code; see "Same vendor vs. cross-vendor"
below for why that's weaker than cross-vendor review but still worth
having. An invalid model name fails loudly (exit 1, no round appended)
rather than silently producing an empty review.

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

## License

MIT — see [LICENSE](LICENSE).
