---
id: A045
spec: apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The "tears down listeners on unmount" test (lines 83-93) fires THREE different
listener channels after unmount (focus, visibilitychange, store setActive) and
asserts the reconciler was not called. This is good defensive coverage of
unmount, but it hides three failure modes behind one assertion: if production
correctly unsubscribes the focus listener but FAILS to unsubscribe the
visibilitychange listener, the single `expect(reconcile).not.toHaveBeenCalled()`
fires with no diagnostic about which channel leaked. A subsequent
"why-did-this-fail" debug session has to manually bisect. More importantly,
the store-subscription unsubscribe is NOT actually tested in isolation — if
the hook never subscribes to `usePlayerStore` (e.g. it polls instead), this
test still passes. The setActive call on line 91 is the only signal that
exercises the store path, and it's bundled with the other two events.

Secondary: the integration test "full cycle" (lines 109-119) uses
`expect(calls).toContain('p5')` + `toContain('p7')` + `calls[calls.length-1]
=== 'p7'`. This passes even if `calls` is `['p7', 'p5', 'p7']` (i.e. the
reconciler is called in the WRONG ORDER on the intermediate focus event). The
assertion does not pin the ordering, only set-membership + final value. The
"the bug class" framing in the describe title (line 96) suggests ordering
matters for the production bug being prevented.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.test.ts` lines `83-93, 109-119`
- Failing assertion: `expect(reconcile).not.toHaveBeenCalled()` at line 92; `expect(calls[calls.length - 1]).toBe('p7')` at line 118
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/useTtsHighlightReconciler.test.ts`

## Tester Analysis
Recommendations:
1. Split the unmount test into three focused tests: one per listener channel. Each test clears the spy, unmounts, fires ONE event, asserts not called. Failure diagnostics then identify the exact leaked listener.
2. In the "full cycle" test, replace the loose assertions with `expect(calls).toEqual(['p5', 'p5', 'p7'])` (or whatever ordering is documented). If the hook is allowed to coalesce duplicate calls, document it as `expect(calls).toEqual(['p5', 'p7'])` and assert no duplicates.
3. Add a missing test: iframe ref swap during lifetime (the plan section 3 row "useTtsHighlightReconciler" explicitly flags this gap).

Production file: `apps/rishi-electron/src/renderer/src/hooks/useTtsHighlightReconciler.ts`.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

## Reviewer-1 Verdict: TEST-QUALITY-B
**Agent type:** team-reviewer
**Flake check:** N/A (not a bug claim)
**Reasoning:** Production code at `useTtsHighlightReconciler.ts:36-56` correctly subscribes to `usePlayerStore` AND removes all listeners on unmount — no production bug. The unmount test (test lines 83-93) does bundle three channels into one assertion (focus/visibilitychange/setActive), which weakens diagnostics on failure but still fails if ANY of the three leaks, so the test does its job — coverage is real, only granularity suffers. The finding's stronger claim that "if the hook polled instead of subscribed, this test still passes" is weakened by test lines 36-42 (`re-invokes the reconciler when activeParagraph changes`), which exercises the store-subscription path synchronously and would fail for a polling implementation. The "full cycle" assertion at line 118 (`calls[calls.length - 1] === 'p7'` + `toContain`) is genuinely loose — it tolerates intermediate out-of-order calls like `['p7','p5','p7']` — but the documented invariant (final state converges to active paragraph) is still asserted; the ordering claim in the finding is a stricter contract than the production hook's docstring (lines 11-14: "Idempotency of `reconcile` is required ... triggers can overlap") promises. The missing iframe-ref-swap test is a real coverage gap (cited by the plan).
**Suggested fix scope (if A or B):** Split the unmount test into three single-event tests for better failure diagnostics, and add a focused iframe-ref-swap test; leave the ordering assertion alone unless the production contract is tightened.
