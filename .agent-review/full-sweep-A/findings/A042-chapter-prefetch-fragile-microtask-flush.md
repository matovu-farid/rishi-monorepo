---
id: A042
spec: apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
`flushPromises()` at lines 47-51 does exactly two `await Promise.resolve()`
ticks, with the comment "Two awaits is enough for then→then chains seen in
the prefetch hook." This hardcodes the depth of the implementation's
`.then()` chain. If the production hook adds an intermediate `.then()`
(e.g. logging, error boundary, retry), the test silently skips the final
assertion's preconditions — `setCurrentSpy` / `setNextSpy` / `setPrevSpy`
will not have been called by the time the assertion runs, but instead of a
clean failure, the test may fail intermittently (when the scheduler
interleaves differently) or fail with a confusing "expected to be called"
message that points at the assertion, not at the missed microtask. This is
the classic timing-flake pattern flagged in the plan section 4 ("setTimeout(0)
flushes instead of waitFor — non-deterministic").

## Reproduction
- Test file: `apps/rishi-electron/src/renderer/src/hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts` lines `47-51, 68-75, 92-100`
- Failing assertion: indirect — `expect(setCurrentSpy).toHaveBeenCalledWith(...)` at line 71 depends on `flushPromises()` having drained all microtasks.
- How to run: `pnpm --filter rishi-electron test src/renderer/src/hooks/reader/__tests__/useChapterParagraphPrefetch.test.ts`
- To force the failure mode: add a third `.then()` to the prefetch implementation (e.g. `.then((x) => x)`); the tests will start failing flakily.

## Tester Analysis
Replace `flushPromises()` with `await waitFor(() => expect(setCurrentSpy).toHaveBeenCalled())`. `waitFor` polls and tolerates any depth of microtask chain. The current pattern is brittle precisely because it encodes the implementation's chain depth, not the observable contract ("setCurrentParagraphs eventually gets called with the prefixed paragraphs").

Secondary concern (same file, lines 149-167): the unmount test doesn't `advanceTimersByTime(300)` before unmount, so it never exercises the case where the 300ms debounce timer is in-flight at unmount — a likely real bug surface (debounce fires after unmount, setNextSpy called on a stale closure). Worth adding as a follow-up test.

Production file: `apps/rishi-electron/src/renderer/src/hooks/reader/useChapterParagraphPrefetch.ts`.

## Reviewer-1 Verdict: TEST-QUALITY-B
**Agent type:** general-purpose (acting for feature-dev:code-reviewer)
**Flake check:** 5/5 passes locally (293-298ms each, fake timers). Test is currently green and stable; the brittleness is latent, not active.
**Reasoning:** Production hook `useChapterParagraphPrefetch.ts:50-69` has shallow `fetcher().then(cb)` chains (depth 1), which `flushPromises()` (lines 47-51, two `await Promise.resolve()`) correctly drains today — first await settles the mocked `Promise.resolve([...])`, second runs the `.then` callback that calls `setCurrentParagraphs`. The finding is accurate that this encodes implementation depth, not the observable contract: adding any intermediate `.then` (logging, parse, retry) would silently break the precondition for `expect(setCurrentSpy).toHaveBeenCalledWith(...)` at lines 71, 96-99 without a clear error. This is not a production bug and not a current test failure — it's a maintainability/brittleness smell (TEST-QUALITY-B). The secondary concern about unmount-during-debounce (lines 149-167 never `advanceTimersByTime(300)` before `unmount()`) is a real coverage gap but also a follow-up rather than a current failure.
**Suggested fix scope (if A or B):** Replace `flushPromises()` calls with `await waitFor(() => expect(setCurrentSpy).toHaveBeenCalled())` style polling, and add one test that advances timers partway (e.g. 150ms) then unmounts to assert the debounced prefetch never lands.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
