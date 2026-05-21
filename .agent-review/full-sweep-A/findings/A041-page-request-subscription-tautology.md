---
id: A041
spec: apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/usePageRequestSubscription.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The "does not re-subscribe when callbacks change across renders" test
(lines 96-108) measures subscriptions via a wrapped `usePlayerStore.subscribe`
counter but never asserts a baseline expectation about HOW MANY subscriptions
the hook makes on mount. It only checks that the count is equal across renders.
If the hook regresses to call `usePlayerStore.subscribe` zero times (e.g. it
silently swallows the subscribe call because of a refactor that breaks ref
plumbing), `subsAfterMount === 0` and `subscribeCount === 0` after rerenders,
and the test still passes. The test is also tautological for the
regression-of-interest: a hook that registers via `useSyncExternalStore` (the
React-idiomatic alternative) doesn't go through `usePlayerStore.subscribe` at
all — so this counter would always be 0 and any future migration would not be
caught.

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/usePageRequestSubscription.test.ts` lines `96-108`
- Failing assertion: `expect(subscribeCount).toBe(subsAfterMount)`
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/usePageRequestSubscription.test.ts -t "does not re-subscribe"`

## Tester Analysis
Two problems compound:
1. No assertion that `subsAfterMount === 1` (or any specific number) — the
   contract "subscribes exactly once on mount" is not tested.
2. Subsequent test ("routes pageRequest events to the latest callback after
   re-render", lines 110-125) only verifies that the LATEST callback fires
   after a rerender, not that the FIRST callback is unsubscribed. A hook that
   stacks subscriptions on each render (and fires both) would only fail the
   "first not called" assertion via `expect(firstOnNext).not.toHaveBeenCalled()`
   IF the hook also routes to the latest. If the production hook keeps each
   subscription alive and BOTH fire, only the latter check fails — but a
   coder seeing one failure could "fix" by adding latest-wins gating without
   tearing down the prior subscription, producing a leak. Pair this with a
   positive "subscribes exactly once" baseline assertion.

Production file: `apps/rishi-electron/src/renderer/src/hooks/reader/usePageRequestSubscription.ts`.

## Reviewer-1 Verdict: TEST-QUALITY-B
**Agent type:** team-reviewer
**Flake check:** N/A (not a flake — test-quality finding, production code currently correct)
**Reasoning:** Confirmed. Test at `usePageRequestSubscription.test.ts:96-108` only asserts `subscribeCount === subsAfterMount` without pinning `subsAfterMount` to a concrete expected value (should be `=== 1`). Inspecting production `usePageRequestSubscription.ts:38-50` shows the hook does subscribe exactly once via `usePlayerStore.subscribe(...)`. Two concrete failure modes pass this test: (a) a refactor that prevents the subscribe call entirely (`subsAfterMount === 0 && subscribeCount === 0` still passes), and (b) a migration to `useSyncExternalStore` would bypass `usePlayerStore.subscribe` entirely (count stays 0). Additionally, the companion test at lines 110-125 verifies latest-callback routing but does not assert that the prior subscription is torn down — a leaky implementation that stacks subscriptions and dispatches to all of them would pass `expect(firstOnNext).not.toHaveBeenCalled()` only if a latest-wins gate is added inside the handler, not via proper unsubscribe. The Tester's analysis is accurate on both counts.
**Suggested fix scope (if A or B):** Add `expect(subsAfterMount).toBe(1)` baseline assertion in the re-subscribe test, and add a dedicated assertion that the prior subscription's unsubscribe is invoked (or that stacked dispatch does not occur) to catch subscription leaks.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
