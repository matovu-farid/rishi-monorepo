# Multi-Agent Test Review — Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the pilot phase of the multi-agent test-review workflow on the warm-restore slice. Triage 4 specs + counterparts, produce confirmed findings, fix confirmed bugs via TDD, verify with mutation checks. Validate the workflow before scaling to the full sweep.

**Architecture:** The "implementation" is *orchestration*. The orchestrator (Claude main thread) reads the spec at `docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md`, dispatches subagents in waves, parses their file output, advances `INDEX.md`, and gates between waves. Each wave is one or more `Agent` tool dispatches. All findings, dialog, fixes, and verifications are persisted under `.agent-review/pilot/`.

**Tech Stack:** Claude Agent dispatch, Vitest, Playwright, the existing rishi-electron repo. No new dependencies.

**Scope of this plan:** Pilot only. Full sweep is a separate plan written after pilot lessons.

**Spec reference:** `docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md`

---

## Wave 0: Setup

### Task 0.1: Scaffold review directory and gitignore

**Files:**
- Create: `.agent-review/pilot/findings/.gitkeep`
- Create: `.agent-review/pilot/INDEX.md`
- Create: `.agent-review/pilot/parity-gaps.md`
- Create: `.agent-review/pilot/practices-audit.md`
- Create: `.agent-review/FINDING-TEMPLATE.md`
- Modify: `.gitignore` (repo root)

- [ ] **Step 1: Add `.agent-review/` to repo-root `.gitignore`**

Append this block to `/Users/faridmatovu/projects/rishi-monorepo/.gitignore`:

```
# Multi-agent test review artifacts (per docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md)
.agent-review/
```

Verify:
```bash
grep -q "^\.agent-review/$" /Users/faridmatovu/projects/rishi-monorepo/.gitignore && echo "OK"
```
Expected: `OK`

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings
touch /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/.gitkeep
```

- [ ] **Step 3: Write the finding-file template**

Write `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md`:

```markdown
---
id: NNN
spec: e2e/<spec-name>.spec.ts
status: open
created: YYYY-MM-DD
reviewer1_agent_type: team-reviewer | feature-dev:code-reviewer
dispatches_used: 0
---

## Bug Summary
<one paragraph: what's wrong, where, expected vs actual>

## Reproduction
- Test file: `<exact/path/to/spec.ts>` lines `<L1-L2>`
- Failing assertion: `<paste the assertion>`
- How to run: `<exact command>`

## Tester Analysis
<why this is a production bug, not a test problem; cite production code paths>

## Reviewer-1 Verdict: CONFIRM | REJECT
<append after wave 3>

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
<append after wave 6 starts; TDD: red → minimal change → refactor>

## Code Review
<append after coder commits; approve / request changes>

## Coder Rebuttal
<append if review requested changes; ACCEPT or REBUT>

## Code-Review Tiebreaker
<append if rebut; binding>

## Mutation Check
<append after wave 7; "Production fix reverted at <SHA-or-stash-id>; test failed as expected. Restored; test passes.">

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
```

- [ ] **Step 4: Write the initial INDEX.md**

Write `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/INDEX.md`:

```markdown
# Pilot — Test Review Index

## Wave Status

| Wave | Status | Started | Completed |
|---|---|---|---|
| 0. Setup | in-progress | 2026-05-20 | |
| 1. Plan | pending | | |
| 2. Triage | pending | | |
| 3. Reviewer-1 | pending | | |
| 4. Rebuttal | pending | | |
| 5. Tiebreaker | pending | | |
| 6. Fix | pending | | |
| 7. Mutation check | pending | | |
| 8. Summary | pending | | |

## Findings

| ID | Spec | Current Stage | Reviewer-1 Outcome | Tiebreaker | Fix Commit | Mutation Passed | Dispatches Used |
|---|---|---|---|---|---|---|---|

## Parity Gaps
See `parity-gaps.md`.

## Practice Violations
See `practices-audit.md`.

## Dispatch Budget
- Soft cap: 60 dispatches for pilot
- Hard per-finding cap: 8 dispatches
- Current global count: 0
```

- [ ] **Step 5: Write parity-gaps.md and practices-audit.md skeletons**

Write `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/parity-gaps.md`:
```markdown
# Pilot — Parity Gaps

Format-pair parity gaps surfaced during triage. Not bugs; tracked for follow-up.

<testers append entries here>
```

Write `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/practices-audit.md`:
```markdown
# Pilot — Practices Audit

Best-practice violations in existing tests. Not bugs in production; tracked for follow-up.

<testers append entries here>
```

- [ ] **Step 6: Verify scaffold**

```bash
ls -la /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/
ls -la /Users/faridmatovu/projects/rishi-monorepo/.agent-review/
```
Expected output includes: `INDEX.md`, `parity-gaps.md`, `practices-audit.md`, `findings/`, and `../FINDING-TEMPLATE.md`.

Verify gitignore working:
```bash
cd /Users/faridmatovu/projects/rishi-monorepo && git status --short .agent-review/
```
Expected: empty output (gitignored).

- [ ] **Step 7: Update INDEX.md wave 0 status to done**

Edit `.agent-review/pilot/INDEX.md`: change `0. Setup | in-progress` to `0. Setup | done` and fill completed timestamp.

---

## Wave 1: Plan

### Task 1.1: Dispatch the planner

**Files:**
- Create (by agent): `.agent-review/pilot/plan.md`

- [ ] **Step 1: Mark wave 1 in-progress in INDEX.md**

- [ ] **Step 2: Dispatch the planner agent**

Use the `Agent` tool with `subagent_type: team-planner`:

```
description: "Pilot plan for warm-restore test review"

prompt:
You are the planner for the pilot phase of a multi-agent test-review workflow.
Spec: /Users/faridmatovu/projects/rishi-monorepo/docs/superpowers/specs/2026-05-20-multi-agent-test-review-design.md
Template: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md

PILOT SCOPE — read these and only these:
- apps/rishi-electron/e2e/pdf-warm-restore.spec.ts
- apps/rishi-electron/e2e/epub-warm-restore.spec.ts
- apps/rishi-electron/e2e/azw3-real-import-routing.spec.ts (focus on warm-restore-relevant tests)
- apps/rishi-electron/e2e/mobi.spec.ts (focus on warm-restore-relevant tests)
- apps/rishi-electron/src/renderer/src/stores/pdfStore.test.ts
- apps/rishi-electron/src/renderer/src/stores/epubStore.test.ts
- apps/rishi-electron/src/main/ipc/__tests__/formats-mobi.test.ts
- Their production-code targets (the stores/IPC handlers they test).

WRITE: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/plan.md

The plan.md MUST contain these sections:

1. **Parity matrix.** Markdown table: rows = format (PDF/EPUB/MOBI/AZW3), columns = warm-restore-related capabilities (cold open → reopen state, page/CFI restore, scroll position, recently-opened ordering, ...). Cell = ✓ tested / ✗ no test / N/A.

2. **Per-spec audit checklist.** For each of the 4 specs, list the specific anti-patterns and parity gaps to look for, e.g.:
   - "pdf-warm-restore tests page restoration; does epub-warm-restore test CFI restoration equivalently?"
   - "Does any test mock the database when it shouldn't?"

3. **TDD architecture guidance.** When a tester surfaces a bug, what does the red test look like? Where does it belong (e2e vs unit)? What naming conventions does this codebase use? (Read existing tests to derive — don't invent.)

4. **Finding-file rules.** Re-state the template. Re-state that the cap on findings per spec is 5 (testers should not pad). Re-state that "parity gap" and "practice violation" are not bugs — they go in parity-gaps.md and practices-audit.md, not findings/.

5. **Test commands.** Exact pnpm commands testers will run later to verify failure (vitest specific file, playwright specific file).

DO NOT write any findings. DO NOT modify any production code or test code. Output is exactly one file: plan.md.

Return a 1-paragraph summary of what you wrote.
```

- [ ] **Step 3: Verify plan.md exists and is non-trivial**

```bash
test -s /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/plan.md && wc -l /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/plan.md
```
Expected: file exists, ≥80 lines.

- [ ] **Step 4: Skim plan.md for the 5 required sections**

Read the file. Confirm presence of: parity matrix, per-spec audit checklist, TDD architecture guidance, finding-file rules, test commands. If any missing, re-dispatch planner with a corrective addendum.

- [ ] **Step 5: Update INDEX.md wave 1 status to done; increment dispatch count to 1**

---

## Wave 2: Triage (parallel ×4)

### Task 2.1: Dispatch 4 testers in parallel

**Files:**
- Read by agents: plan.md, assigned spec, counterpart, production code
- Write by agents: `.agent-review/pilot/findings/NNN-<slug>.md`, append to `parity-gaps.md` and `practices-audit.md`

- [ ] **Step 1: Mark wave 2 in-progress in INDEX.md**

- [ ] **Step 2: Dispatch all 4 testers in ONE message with 4 Agent calls**

Tester prompt template (substitute `<SPEC>`, `<COUNTERPART>`, `<ID_RANGE>` for each):

```
description: "Triage <SPEC>"
subagent_type: team-tester

prompt:
You are a tester in the pilot phase of a multi-agent test-review workflow.
Read first: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/plan.md
Template: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md

YOUR ASSIGNED FILES:
- Primary spec: apps/rishi-electron/<SPEC>
- Counterpart: apps/rishi-electron/<COUNTERPART>
- Production code under test: discover by reading the spec's imports / test targets

YOUR JOB:
1. For each SUSPECTED PRODUCTION BUG you find (the test reveals real broken behavior in production code):
   - Copy FINDING-TEMPLATE.md to .agent-review/pilot/findings/<ID>-<short-slug>.md
   - Your ID range for this dispatch is <ID_RANGE> (e.g., 001-005). Stay within range.
   - Fill: Bug Summary, Reproduction (with exact lines and command), Tester Analysis.
   - Set status: open, dispatches_used: 1.
   - Set reviewer1_agent_type: <ROTATING> (see below).
2. For each PARITY GAP (a capability tested in one format but missing in another, not a bug per se):
   - Append a bullet to .agent-review/pilot/parity-gaps.md.
3. For each BEST-PRACTICE VIOLATION (mocked-when-shouldn't, brittle timing, impl-detail assertions, etc.):
   - Append a bullet to .agent-review/pilot/practices-audit.md.

REVIEWER-1 ALTERNATION: For each finding you write, set reviewer1_agent_type:
- Findings with ODD final-digit ID → "team-reviewer"
- Findings with EVEN final-digit ID → "feature-dev:code-reviewer"

CONSTRAINTS:
- Max 5 findings per tester. Be selective; only file when you can articulate production impact.
- Do NOT modify any production code or test code.
- Do NOT run the tests yet — that's reviewer-1's job.
- Stay in your assigned ID range to avoid clobbering parallel testers' files.

Return: list of finding files created (with IDs), and counts of parity-gap and practice-audit entries appended.
```

Assignments:

| Tester | Spec | Counterpart | ID Range |
|---|---|---|---|
| 1 | `e2e/pdf-warm-restore.spec.ts` | `src/renderer/src/stores/pdfStore.test.ts` | 001-005 |
| 2 | `e2e/epub-warm-restore.spec.ts` | `src/renderer/src/stores/epubStore.test.ts` | 006-010 |
| 3 | `e2e/azw3-real-import-routing.spec.ts` (warm subset) | (no unit counterpart — flag as parity gap) | 011-015 |
| 4 | `e2e/mobi.spec.ts` (warm subset) | `src/main/ipc/__tests__/formats-mobi.test.ts` | 016-020 |

Send all 4 in one message with 4 Agent tool blocks.

- [ ] **Step 3: After all 4 testers return, enumerate findings**

```bash
ls /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/*.md 2>/dev/null
wc -l /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/parity-gaps.md
wc -l /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/practices-audit.md
```

- [ ] **Step 4: Populate INDEX.md findings table**

For each finding file, add a row to the Findings table in INDEX.md with: id, spec, current stage `reviewer-1`, dispatches_used 1.

- [ ] **Step 5: Update INDEX.md wave 2 status to done; increment global dispatch count by 4**

---

## Wave 3: Reviewer-1 (parallel, 1 per finding)

### Task 3.1: Dispatch reviewer-1 per finding

- [ ] **Step 1: Mark wave 3 in-progress in INDEX.md**

- [ ] **Step 2: For each finding file, dispatch reviewer-1**

Send all reviewer-1 dispatches in ONE message (parallel). For each finding `<FILE>`, read the `reviewer1_agent_type` from the frontmatter and use that subagent type. Prompt:

```
description: "Reviewer-1 verdict on finding <ID>"
subagent_type: <team-reviewer OR feature-dev:code-reviewer per file frontmatter>

prompt:
You are Reviewer-1 in a multi-agent test-review workflow. Your job: decide whether the finding describes a real production bug.

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FILE>
Then read: the spec file referenced and the production code the assertion targets.

STEPS — do in this order:
1. FLAKE CHECK. Run the failing test 3 times. The exact command is in the "Reproduction" section.
   - If it passes any of the 3 runs: REJECT with reason "flaky / non-deterministic".
   - If it fails all 3: continue.
2. ASSERTION VALIDITY. Read the assertion. Read the production code it targets. Is the assertion correctly expressing the desired behavior, or is the assertion itself wrong?
   - Assertion wrong → REJECT with reason "test wrong".
3. PRODUCTION IMPACT. If the bug is real, articulate the user-visible impact in one sentence. If you cannot articulate one, REJECT with reason "no user-visible impact".
4. INTENTIONAL DESIGN. Search the codebase (git log, comments) for evidence the current behavior is intentional. If so: REJECT with reason "intentional design", cite source.

APPEND to the finding file (do not overwrite):

## Reviewer-1 Verdict: CONFIRM | REJECT
**Agent type:** <your subagent type>
**Flake check:** ran <N> times, <results>
**Reasoning:** <multi-sentence>
**If REJECT, what would change my mind:** <criteria>

Then update the finding file's frontmatter: increment dispatches_used by 1, set status to "rejected" or leave "open".

DO NOT modify production code, test code, or any other finding file.

Return: the verdict and a one-sentence rationale.
```

- [ ] **Step 3: After all reviewers return, update INDEX.md**

For each finding: update reviewer-1 outcome column. Set current stage to:
- `done` if CONFIRM (will move to fix wave)
- `rebuttal` if REJECT (will move to wave 4)

Wait — important nuance: even a CONFIRM still goes through the rebuttal check (tester confirms they're happy with the verdict, no action needed). Simpler: CONFIRM → skip directly to fix wave. REJECT → wave 4.

- [ ] **Step 4: Update INDEX.md wave 3 status to done; increment global dispatch count by N (# findings)**

---

## Wave 4: Rebuttal (parallel, only rejected findings)

### Task 4.1: Dispatch tester for each rejected finding

- [ ] **Step 1: Mark wave 4 in-progress in INDEX.md (skip wave if no rejects)**

- [ ] **Step 2: For each REJECTED finding, dispatch tester rebuttal**

Send all rebuttals in ONE message (parallel). Prompt:

```
description: "Tester rebuttal on finding <ID>"
subagent_type: team-tester

prompt:
You are the original tester. Reviewer-1 rejected your finding. Decide: accept or rebut?

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FILE>

Steel-manning rule: assume the reviewer's verdict is correct unless you find a specific factual error or missing context they overlooked. Confirmation bias is real; resist it.

APPEND:

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
**Reasoning:** <multi-sentence>
**If REBUT, what evidence the reviewer missed:** <specific>

Update frontmatter: increment dispatches_used, set status to "rejected" (if ACCEPT) or leave "open" (if REBUT).

Return: ACCEPT-REJECTION or REBUT plus one sentence.
```

- [ ] **Step 3: Update INDEX.md**

For each rejected finding: current stage = `tiebreaker` if REBUT, else `done` (rejected, closed).

- [ ] **Step 4: Update INDEX.md wave 4 done; increment dispatch count**

---

## Wave 5: Tiebreaker (parallel, only rebutted findings)

### Task 5.1: Dispatch tiebreaker for each rebutted finding

- [ ] **Step 1: Mark wave 5 in-progress (skip if no rebuttals)**

- [ ] **Step 2: For each REBUTTED finding, dispatch tiebreaker**

Tiebreaker uses whichever of `team-reviewer` / `feature-dev:code-reviewer` was NOT used for Reviewer-1 (read from frontmatter).

```
description: "Tiebreaker verdict on finding <ID>"
subagent_type: <the OTHER type>

prompt:
You are the tiebreaker. Reviewer-1 rejected; the tester rebutted. Make the binding final call.

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FILE>
Read the spec and the production code. Run the test yourself if needed.

APPEND:

## Tiebreaker Verdict: CONFIRM | REJECT
**Agent type:** <your type>
**Reasoning:** <multi-sentence — must explicitly address both Reviewer-1's rejection and the tester's rebuttal>

Update frontmatter: increment dispatches_used, set status to "confirmed" or "rejected".

Return: verdict.
```

- [ ] **Step 3: Update INDEX.md tiebreaker column for each disputed finding; current stage = `fix` if CONFIRM, `done` if REJECT**

- [ ] **Step 4: Wave 5 done; increment dispatch count**

---

## Wave 6: Fix (sequential, only CONFIRMED findings)

### Task 6.1: For each confirmed finding, run the fix subloop

This wave is **strictly sequential**. One confirmed finding at a time. Do NOT parallelize.

- [ ] **Step 1: Mark wave 6 in-progress in INDEX.md**

- [ ] **Step 2: Build the list of confirmed findings**

Read INDEX.md. Confirmed = status `confirmed` in frontmatter OR (Reviewer-1 CONFIRM and no rejection) OR (Tiebreaker CONFIRM). Order by ID.

- [ ] **Step 3: For each confirmed finding `<FINDING>`, run the fix subloop**

**Sub-step 6.3.a — Track remaining per-finding dispatches**

Read the finding's `dispatches_used` from frontmatter. Maximum so far is 3 (reviewer-1 + rebuttal + tiebreaker). This wave can add up to 4 more (coder + code-review + coder-rebuttal + code-review-tiebreaker) before hitting the per-finding cap of 8 (last slot reserved for mutation check). If during this wave a finding tries to use a 4th dispatch and would push the total past 7, skip the rebuttal/tiebreaker path and either accept the code review verdict as-is or escalate to user.

**Sub-step 6.3.b — Dispatch the coder**

```
description: "Fix <FINDING>"
subagent_type: team-coder

prompt:
You are the coder for finding <FINDING>. Implement the fix via TDD.

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FINDING>
This finding is CONFIRMED. Implement the fix.

TDD PROCESS:
1. RED — Ensure a test exists that fails because of this bug. The Reproduction section names the test. If the assertion isn't quite right or missing, write/adjust the test FIRST. Run it. Confirm it fails.
2. GREEN — Write the minimal production code change to make the test pass. Do NOT refactor unrelated code. Do NOT add abstractions.
3. VERIFY — Run the full test suite for the affected app: `pnpm --filter rishi-electron test` (and `pnpm --filter rishi-electron test:e2e <spec>` for e2e). Make sure nothing else broke.
4. COMMIT — One atomic commit. Message: "fix(test-review-<ID>): <short description>". Body: link to the finding file.

If your fix breaks an unrelated test: revert your changes, append a note to the finding's Fix Plan section explaining why, and stop. Do not fix-on-fix.

APPEND to the finding file:

## Fix Plan
<your TDD plan as executed>

Update frontmatter: increment dispatches_used, set status to "fixed", record commit SHA.

Return: commit SHA + summary of what changed.
```

**Sub-step 6.3.c — Dispatch code-reviewer**

```
description: "Code review for <FINDING> fix"
subagent_type: team-reviewer

prompt:
Review the coder's diff for finding <FINDING>.

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FINDING>
Then: `git show <COMMIT_SHA>`

CHECKLIST:
- Does the fix actually address the root cause described in the finding (not just paper over the symptom)?
- Is the scope minimal? Any unrelated changes (formatting, refactors, abstractions)?
- Does it follow this repo's conventions? (Check neighboring code.)
- Any new bugs introduced?

Confidence threshold: only report issues you are ≥80% sure of (per team-reviewer skill).

APPEND:

## Code Review
**Verdict:** APPROVE | REQUEST-CHANGES
**Findings:** <bulleted list, or "none">

Update frontmatter: increment dispatches_used.

Return: APPROVE or REQUEST-CHANGES.
```

**Sub-step 6.3.d — Handle review outcome**

- If APPROVE: proceed to next finding.
- If REQUEST-CHANGES: dispatch coder rebuttal (one round only).

Coder rebuttal prompt:
```
description: "Coder rebuttal on <FINDING>"
subagent_type: team-coder

prompt:
Review the code-review feedback on finding <FINDING>. Decide: accept and amend, or rebut?

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FINDING>

If you accept: make the changes, amend or add a follow-up commit, append:
## Coder Rebuttal
**Verdict:** ACCEPT
**Changes:** <commit SHA>

If you rebut: explain why the reviewer is wrong, factually.
## Coder Rebuttal
**Verdict:** REBUT
**Reasoning:** <specific>

Update frontmatter: increment dispatches_used.
Return: ACCEPT or REBUT.
```

**Sub-step 6.3.e — Code-review tiebreaker (only if rebut)**

Use `feature-dev:code-reviewer`. Binding verdict. Append `## Code-Review Tiebreaker`. If tiebreaker says changes are needed, coder applies them (no further rebuttal — cap reached).

**Sub-step 6.3.f — Verify the test passes one more time before moving on**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo && pnpm --filter rishi-electron test <unit-test-path-if-applicable>
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron && pnpm test:e2e <e2e-path-if-applicable>
```
Expected: target test passes.

**Sub-step 6.3.g — Update INDEX.md**

Current stage = `mutation-check`, fix commit column = SHA, dispatches_used updated.

- [ ] **Step 4: After all confirmed findings processed, mark wave 6 done**

---

## Wave 7: Mutation Check (sequential, only fixed findings)

### Task 7.1: For each fixed finding, run mutation check

Sequential because parallel revert+restore on a shared working tree would conflict.

- [ ] **Step 1: Mark wave 7 in-progress**

- [ ] **Step 2: Verify working tree is clean before starting**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo && git status --short
```
Expected: empty.

- [ ] **Step 3: For each fixed finding, dispatch mutation checker**

```
description: "Mutation check <FINDING>"
subagent_type: team-tester

prompt:
You are the mutation checker for finding <FINDING>. Prove the test actually exercises the fix.

Read: /Users/faridmatovu/projects/rishi-monorepo/.agent-review/pilot/findings/<FINDING>
Fix commit SHA: <SHA>

STEPS:
1. Verify working tree is clean. If not, STOP and report.
2. Identify the production-code portion of the fix commit (not the test changes). Use `git show <SHA> --stat` and `git show <SHA> -- '<production-paths>'`.
3. Create a revert that touches ONLY the production code (not the test file): `git revert --no-commit <SHA>`, then `git restore --staged <test-files>` and `git checkout -- <test-files>` to keep the test changes in place.
4. Run the test that was supposed to catch this bug (command in finding's Reproduction section). It MUST fail. If it passes, the test is INVALID — escalate.
5. Restore: `git restore --staged --worktree .` (drops the revert).
6. Run the test again. It MUST pass.
7. Verify working tree is clean again.

APPEND:

## Mutation Check
**Result:** PASSED | FAILED | TEST-INVALID
**Reverted hunk:** <production paths reverted>
**Test failed without fix:** YES | NO
**Test passed with fix restored:** YES | NO

Update frontmatter: increment dispatches_used, set status to "verified" if PASSED.

Return: PASSED | FAILED | TEST-INVALID.

DO NOT commit anything. DO NOT modify the test file or fix permanently. Leave working tree clean.
```

- [ ] **Step 4: For each mutation result, update INDEX.md mutation-passed column**

- [ ] **Step 5: If any mutation check FAILED or TEST-INVALID, surface to user before continuing**

Do not silently move on from a TEST-INVALID. This means a confirmed bug's fix isn't actually exercised by the test. User decides whether to re-fix or accept.

- [ ] **Step 6: Wave 7 done**

---

## Wave 8: Summary

### Task 8.1: Finalize and report

- [ ] **Step 1: Mark wave 8 in-progress**

- [ ] **Step 2: Finalize INDEX.md**

Update INDEX.md to reflect final state:
- All wave statuses = done
- Final global dispatch count
- Findings table fully populated

- [ ] **Step 3: Append a "Pilot Outcome" section to INDEX.md**

```markdown
## Pilot Outcome (2026-05-20)

**Findings totals:**
- Filed: N
- Confirmed by Reviewer-1: N
- Rejected by Reviewer-1: N
- Tiebreaker overturned: N
- Fixed + mutation-verified: N
- Fixed but mutation FAILED (test invalid): N

**Parity gaps documented:** N
**Practice violations documented:** N

**Workflow health signals:**
- Reviewer-1 outcomes split: <Confirm%> / <Reject%>  (expected: not 100%/0% in either direction)
- Tiebreaker overturn rate: <%>  (high rate signals Reviewer-1 calibration issue)
- Per-finding dispatches: median <N>, max <N>  (cap was 8)
- Total dispatches: <N>  (budget was 60)

**Recommendation for full sweep:** SCALE | ADJUST | HALT
<reasoning>
```

- [ ] **Step 4: Report to user**

Summarize: how many bugs were confirmed and fixed, what parity gaps and practice violations were found, whether the workflow is healthy enough to scale, and any specific findings that need human review (mutation failures, escalations).

- [ ] **Step 5: Mark wave 8 done in INDEX.md**

- [ ] **Step 6: Commit the .agent-review artifacts as a single record**

Wait — `.agent-review/` is gitignored intentionally. Do NOT commit it. The fix commits from wave 6 are the only things that enter git history. The audit trail lives locally.

If the user later wants the audit trail in git: that's a separate decision; for now, gitignored is correct.

---

## Resumability Notes

Any future session can resume by:

1. Read `.agent-review/pilot/INDEX.md` wave status table.
2. The first wave not marked `done` is where to pick up.
3. Within that wave, the findings table shows which findings are at which stage.
4. Re-dispatching an agent for a stage already completed is wasteful but not harmful — agents append, they don't overwrite (per their prompts). Still, prefer to pick up at the exact frontier.

---

## What This Plan Does Not Cover

- The full sweep. Separate plan, written after pilot lessons.
- Committing the `.agent-review/` directory itself.
- Test infrastructure changes (no new runners or frameworks).
- Backporting tests to mobile/web (electron only per repo convention).
