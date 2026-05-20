---
description: Six-lens parallel review of the current branch's diff vs main — architect, reviewer, tester, coder-clarity, planner, researcher
argument-hint: [optional scope hint — e.g. a feature name or file path]
---

Run a six-lens review of the current branch's changes. Optional scope hint from the user: $ARGUMENTS

## Step 1 — Get the diff scope

Default: everything on the current branch vs `main`. Use:

!`git diff --stat main..HEAD`

If the user passed a scope argument, narrow to those files/dirs. If the branch has uncommitted changes that haven't been committed yet, include them via `git status` + working-tree diff.

## Step 2 — Dispatch the six agents IN PARALLEL

Send a single message with six Agent tool calls. Each prompt must be self-contained (the agent has no shared context) — include the diff scope, the feature intent, and the specific lens.

1. **team-architect** — architectural fit. Are new modules in the right layer? Are interface members optional-when-required or vice versa? Does the change respect existing patterns? Under 350 words.

2. **team-reviewer** — bugs, security, cost regressions, observability gaps. Confidence-filter ≥80%. File:line refs. Severity tags. Under 400 words.

3. **team-tester** — coverage audit. Missing edge cases (with specific test names), fragile timing assumptions, tests-of-implementation vs tests-of-contract. Under 400 words.

4. **general-purpose** (clarity lens) — maintainability from a 6-months-later reader's perspective. Confusing names, WHAT-only comments, missing WHYs, premature abstractions. Under 350 words.

5. **Plan** (sanity-check lens) — was the chosen approach the right one? Production gotchas the tests miss. Should this ship as-is, behind a flag, or be redesigned? Under 350 words.

6. **team-researcher** — verify upstream SDK assumptions the code makes. Read installed package source where applicable. Confirm or refute. Under 400 words.

## Step 3 — Synthesize

Consolidate findings into a single punch list, deduplicated. Sort by severity:

- 🔴 **Block ship** — real bugs, security issues, privacy regressions
- 🟡 **Important** — UX risks, missing observability, design call needed
- 🟢 **Polish** — naming, comments, dead code

**Fact-check before passing along**: agents are sometimes wrong. For any 🔴 finding, briefly verify against the actual code before reporting it. Flag any agent claims that are false alarms.

## Step 4 — Recommend next steps

Group findings into "fix now" vs "defer". Ask the user which to act on, unless the user said "autonomous" — then act on everything 🔴 + 🟡.

## Notes for the orchestrator (you)

- Parallel dispatch is mandatory — one message, six tool calls. Sequential wastes wall time.
- Each agent's prompt should reference the diff (use `git diff main` or the user's scope) so the agent isn't searching blind.
- Trust but verify every 🔴 finding before surfacing.
