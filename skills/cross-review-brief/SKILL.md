---
name: cross-review-brief
description: Use right before or after running cross-review.sh on a change, whenever task.md still has its stub placeholder, to write task.md from the conversation's original ask rather than a retrospective summary of the work. Triggers on "brief this for cross-review", "write the cross-review task.md", "prep this for cross-review".
---

# Cross-Review Brief

Populates `task.md` for a `cross-review.sh` session (see the `cross-review`
repo) from the conversation's *original* ask — not a self-graded summary of
the work just done. This is what keeps the review honest: the reviewer
checks the diff against what was actually requested, not against the
author's account of what it accomplished. Timing doesn't matter — you can
run this whether you decided to cross-review at the start, middle, or end
of the task, because the content is the ask itself (a fixed fact), not a
judgment about the outcome (which would drift depending on when you wrote
it).

## Hard rule

Do not write:
- Whether the diff satisfies the goal
- A description of your implementation approach
- Any quality self-assessment ("this correctly handles X")

Only write what was asked, in the asker's own words wherever you can quote
or closely paraphrase them, plus any explicit scope boundaries stated
during the conversation. If you weren't present for the original ask (e.g.
resuming someone else's session), say so explicitly rather than inventing
one.

## Steps

1. Find the target session:
   - If given a session dir, use it.
   - Otherwise find the most recent `.cross-review/*` dir in the current
     repo. If none exists, run `cross-review.sh init <slug>` first (ask
     for a slug if one wasn't given).
2. Scan back through the conversation to the point where this change's
   goal was actually stated — the user's request, or your own stated plan
   if you set the goal yourself (e.g. self-directed cleanup) — and
   extract:
   - **Goal**: quote or closely paraphrase it.
   - **Constraints / scope**: anything explicitly ruled in or out, e.g.
     "don't touch the API," "just the refactor, no behavior change."
   - **Explicitly deferred**: anything named as out of scope for *this*
     change but relevant, so the reviewer doesn't flag it as a miss.
3. Write `task.md` in the session dir using the template below,
   overwriting the stub. Do not add sections beyond the template.
4. Tell the user the brief is written and treat it as frozen for this
   review cycle — same as the diff, don't edit it mid-review.

## Template

```markdown
## Goal
<quoted or closely paraphrased original ask>

## Constraints / scope
<explicit boundaries stated during the conversation, or "None stated.">

## Explicitly deferred
<named out-of-scope items for this change, or "None stated.">

## Source
<where this came from, e.g. "user's request at the start of this session"
or "resumed session — original ask not visible, reconstructed from commit
message">
```
