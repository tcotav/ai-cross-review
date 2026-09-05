# cross-review

A minimal cross-vendor review harness for Claude Code, Codex CLI, and
Antigravity (`agy`). One tool writes code; a *different* vendor's model
reviews it in a ledger (`findings.md`) that accumulates across rounds.
Why: a model reviewing its own output tends to share the same priors and
blind spots that produced the bug — a different vendor doesn't.

This is deliberately thin: no spec/plan/task management, no automatic
looping. You decide when to run another round.

## Usage

**Do this before firing anything off:**

1. Finish one focused unit of work. Don't batch unrelated changes —
   smaller diffs are cheaper to review and easier for the reviewer to
   get right.
2. **Review before you commit.** `init` with no `--base` diffs against
   `HEAD`; if you've already committed, `HEAD` *is* your change and
   you'll get an empty review. (To review something already committed,
   pass `--base <ref-before-it>` explicitly.)
3. Ask for the brief immediately, while the ask is still recent in
   conversation — it's cheaper for whoever writes `task.md` than
   scanning back through a long session later.
4. Fix real findings in-session rather than via headless `respond`.
5. Re-review once to confirm, not by default in a loop — every round
   resends the whole ledger, so cost scales with round count too, not
   just diff size.
6. Commit last, once it settles. Start a fresh session for the next
   unit of work rather than growing this one's ledger indefinitely.

**Then, just ask** (with Claude Code or whatever agent you're using):

> brief this for cross-review and get a codex review

It runs the `cross-review-brief` skill to write `task.md` from what you
actually asked for earlier in the conversation — not a self-graded
summary of the work, which would reintroduce the rationalization
problem this whole thing exists to avoid — then drives `init` →
`review` → reads `findings.md` and fixes what's real. Say which vendor
to review with; if you don't, it should ask rather than assume.

### Manual CLI

For scripting, CI, or outside an agent session:

```bash
./cross-review.sh init auth-rework          # freezes the uncommitted diff
$EDITOR .cross-review/*-auth-rework/task.md # describe the goal/spec
./cross-review.sh review .cross-review/*-auth-rework --with codex
# read findings.md, fix what's real, then re-review to confirm:
./cross-review.sh review .cross-review/*-auth-rework --with codex
./cross-review.sh status .cross-review/*-auth-rework
```

`review`/`respond` also take `--model <name>` to pin a specific model —
see "Same vendor vs. cross-vendor" below. An invalid model name fails
loudly (exit 1) rather than silently producing an empty review.

## Same vendor vs. cross-vendor

Every reviewer invocation is a fresh process with a self-contained
prompt (`task.md` + `diff.patch` + `findings.md`) — nothing resumes a
prior session, so reviewing with the same vendor (even the same model,
via `--model`) won't "remember" writing the code. What it won't give
you is protection from *correlated* blind spots: fresh-process
isolation defeats "I remember writing this, so it's fine"
rationalization, but the same weights still tend to miss the same
classes of bugs regardless of memory. Cross-vendor review defends
against both; same-vendor only the first — still better than a
stateful self-review, just not equivalent.

## Requirements

- `git`
- At least two of: `claude` (Claude Code), `codex` (Codex CLI), `agy`
  (Antigravity CLI), each authenticated and on `PATH`.

## Install

Symlink, don't copy — keeps this repo as the source of truth, so
`git pull` here updates everywhere it's linked.

```bash
mkdir -p ~/bin ~/.claude/skills
ln -s "$(pwd)/cross-review.sh" ~/bin/cross-review.sh   # needs ~/bin on PATH
ln -s "$(pwd)/skills/cross-review-brief" ~/.claude/skills/cross-review-brief
```

## The ledger

`findings.md` is the only shared state. Reviewers append `## F<n>`
entries under a `## Round N` header; the author appends
`### Response (author)` blocks under each one — append-only, nobody
rewrites anyone else's entry.

```
## F1 — SQL injection risk in query builder
Reviewer: codex | Round: 1 | Severity: critical | Confidence: 90 | Status: open
File: src/db.py:142

User input is concatenated directly into the query string here.

Suggested fix: build the query with the existing qb.param() helper.

### Response (author)
Status: fixed | Round: 2

Switched to qb.param(), see latest diff.
```

Severity: `critical | major | minor | info`. Confidence: `0-100`.
Status: `open | fixed | wontfix | disputed`.

`status` reports each finding's *final* status and a listing of
anything still open or disputed, plus token usage summed from each
round's header:

```
5 findings — open=2 fixed=1 wontfix=1 disputed=1
Tokens: 4672 across 2 round(s)

Open (awaiting author response):
  F4 [major] Unhandled exception on empty input — src/api.py:80
```

## Status per tool

- **`codex`** — verified against real `codex-cli`. Runs with
  `--sandbox read-only` for review / `workspace-write` for respond, so
  the no-write guarantee is tool-enforced, not just prompted. Token
  usage reporting works too.
- **`claude`** — verified, returns in a few seconds once auth is
  clean. If `claude -p` hangs for minutes, it's almost always a stale
  `ANTHROPIC_API_KEY` env var (invalid keys retry silently before
  erroring) — not this harness. Token usage not yet implemented.
- **`agy`** — untested, no Antigravity install available when this was
  written. Wired up per documented flags; verify before trusting it.

## License

MIT — see [LICENSE](LICENSE).
