---
id: B071
spec: e2e/menu-commands.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`menu-commands.spec.ts` lines 94-127 wrap the "Add Bookmark" menu click in
a five-attempt loop that exits the moment the bookmark count changes,
then asserts `expect(after).toBeGreaterThan(before)`. This contract is
satisfied by any delta ≥ 1, including the bug where a single user-level
"Add Bookmark" click is dispatched twice (e.g. duplicate IPC listener,
double-bound menu handler, or React StrictMode re-mount of the reader's
menu subscriber). Expected: assert the delta is *exactly* 1 on the
attempt that succeeds; actual: any positive delta — even 2, 3, 5 — is
silently accepted as a pass. This is bug-masking in production code
that the test was specifically written to guard.

## Reproduction
- Test file: `apps/rishi-electron/e2e/menu-commands.spec.ts` lines `94-128`
- Failing assertion (current): `expect(after).toBeGreaterThan(before)` (L128)
- Missing assertion: `expect(after - before).toBe(1)` after the loop
  exits successfully
- How to run:
  ```bash
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  pnpm test:e2e e2e/menu-commands.spec.ts -g "Add Bookmark"
  ```

## Tester Analysis
The renderer-side menu subscriber (`menu:command` IPC → `addBookmark`
handler in the PDF reader module) is the exact surface where duplicate
dispatch bugs are most likely to land — adding a second listener
without removing the first, or reacting in both a parent and child
component to the same `menu:command` event. The retry loop's design
(exit-on-change) and the loose `>` comparison combine to make the
single test in the repo that guards this path blind to that whole
class of regression. The plan (`plan-menu-B.md` §2.1 bullet 4) flags
this exact pattern as "Possible bug-masking". The fix is a one-line
assertion strengthening, not a code-shape change — there is no reason
not to bound the delta.

## Reviewer-1 Verdict: CONFIRM | REJECT
<append after wave 3>

## Tester Rebuttal: ACCEPT-REJECTION | REBUT
<append after wave 4, only if rejected>

## Tiebreaker Verdict: CONFIRM | REJECT
<append after wave 5, only if rebutted; binding>

## Fix Plan
<append after wave 6 starts; TDD: red -> minimal change -> refactor>

## Code Review
<append after coder commits; approve / request changes>

## Coder Rebuttal
<append if review requested changes; ACCEPT or REBUT>

## Code-Review Tiebreaker
<append if rebut; binding>

## Mutation Check
<append after wave 7>

## Final Verdict
<commit SHA + verified test pass + mutation check passed>

## Reviewer-1 Verdict: B
**Agent type:** team-reviewer
**Flake check:** N/A (review of test design, not test run)
**Reasoning:** `menu-commands.spec.ts:94-127` does have a real loose-assertion concern — `toBeGreaterThan(before)` (L128) would not distinguish 1 vs 2 bookmarks added, and the menu subscriber in `useMenuCommands.ts` + per-reader handlers (`pdf.tsx:339`, `EpubView.tsx:292`, `Azw3View.tsx:129`, `MobiView.tsx:55`) is exactly the surface where a duplicate-dispatch regression could land. However, the tester's proposed fix (`toBe(1)`) is unsound: the loop only re-clicks when `after === before` at the post-1200ms read (L118-126), so a click whose IPC settled AFTER that read but before the next attempt's read produces a legitimate delta of 2 — flake on the same focus-race the loop was built to absorb. Bug-masking is real but fix scope is wrong; needs to track clicks that actually dispatched (e.g. instrument addBookmark dispatch count, or only count the final successful attempt's contribution).
**Suggested fix scope:** Track per-attempt baseline (`const baseline = after; click; reread`) and assert `after - baseline === 1` only on the iteration that flipped — not a one-line strengthening.
