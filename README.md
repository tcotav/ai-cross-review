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
see "Same vendor vs. cross-vendor" below. An invalid model name or a
failed reviewer call fails loudly (exit 1) rather than silently
producing an empty review. So does a reply that ignores the output
format — no `## F<n>` entries and no "No new findings" line: it's saved
to `round-N-rejected.md` in the session dir instead of the ledger.

The frozen diff (including untracked, non-gitignored files) goes to
another vendor's model verbatim, so files that look like secrets —
`.env*`, private keys, `.netrc`/`.npmrc`, `credentials.json`, etc. —
are replaced with a stub and a warning instead (templates like
`.env.example` pass through). A file renamed away from a sensitive name
(`git mv .env .env.example`), or an exact copy of any sensitive file —
tracked, untracked, or gitignored (`cp .env backup.txt`), including a
committed copy being deleted or edited — is stubbed too. Extend the list with
`CROSS_REVIEW_EXTRA_SENSITIVE="*.tfvars prod-*.yaml"`. It's not a
content scan: secrets pasted into ordinary source files, or an edited
copy of a sensitive file, still go through.

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
- `jq`, if using `agy`.

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

A finding the author answered but deliberately left `open` — e.g. a
major/critical security finding, which the author prompt says not to
dismiss without you — is listed separately under "needs human sign-off".

## Status per tool

- **`codex`** — verified against real `codex-cli`. Runs with
  `--sandbox read-only` for review / `workspace-write` for respond, so
  the no-write guarantee is tool-enforced, not just prompted. Token
  usage reporting works too.
- **`claude`** — verified, returns in a few seconds once auth is
  clean. If `claude -p` hangs for minutes, it's almost always a stale
  `ANTHROPIC_API_KEY` env var (invalid keys retry silently before
  erroring) — not this harness. Token usage not yet implemented.
- **`agy`** — verified against agy 1.3.0, review only. Headless `agy -p`
  auto-denies every tool call (commands, file reads, writes), so the
  reviewer works purely from the inline prompt — that auto-deny is also
  the no-write guarantee. Because allow-grants would switch it off, the
  harness refuses to run agy if any local file agy takes grants from has
  one: `permissions.allow` in your user or admin settings,
  `globalPermissionGrants` in `~/.gemini/config/config.json`, or grants in
  a project record under `~/.gemini/config/projects/` (override with
  `CROSS_REVIEW_AGY_ALLOW_RULES_OK=1` once you've confirmed they can't
  write). This is best effort: it checks only those confirmed grant
  fields, and agy can also hold grants server-side, which the harness
  can't see. It also runs agy from an empty temp directory so
  the reviewed repo's own `.agents/` config and rules files never apply.
  (`--dangerously-skip-permissions` is ignored under `-p`, so grants are
  the only way to give headless agy tools. agy also runs with `--sandbox`
  as an extra layer, but whether that blocks writes is unverified.) `respond --with agy` is refused, since headless
  agy can't write. Token usage works. If `agy -p` fails with "Eligibility check
  failed" on a work account, set `gcp.project` (and `gcp.location`) in
  `~/.gemini/antigravity-cli/settings.json` so it uses the enterprise
  license instead of the consumer one. Per-review timeout is
  `CROSS_REVIEW_AGY_TIMEOUT` (default `900s`); a timeout fails the round
  rather than recording agy's partial output. agy has no stdin input, so
  the whole prompt goes in as one argument — bounded by `ARG_MAX` (about
  1MB on macOS) and growing with the ledger each round; past that the
  review fails loudly.

## License

MIT — see [LICENSE](LICENSE).
