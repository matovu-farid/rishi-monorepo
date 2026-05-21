---
id: B052
spec: e2e/pdf-scroll-up-jitter.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
The jitter-detection loop (L57-65) samples `scrollTop` only for 600ms
after the scroll-up command. The original bug class — placeholder
shrinks to real page dimensions when an off-screen page finishes
rendering — depends on PDF.js render latency. On a slow CI worker, a
cold render can easily exceed 600ms (the test itself uses a 2500ms
settle at L47). A late-frame back-jump that lands at t = 700ms would
never appear in the samples array, and `Math.min(...samples)` would
report the steady-state minimum, masking the regression.

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-scroll-up-jitter.spec.ts` lines `57-77`
- Failing assertion (currently passing but blind):
  ```ts
  while (performance.now() - start < 600) { ... }
  ...
  expect(backJump).toBeLessThan(80)
  ```
- How to run:
  ```bash
  cd apps/rishi-electron
  pnpm test:e2e e2e/pdf-scroll-up-jitter.spec.ts
  ```
- Mutation probe: in the PDF page renderer, delay the
  "measured-dimensions ready" signal by ~700ms (artificial slow
  render). The shrink-then-shift would happen at t≈700ms, after
  sampling stopped. Test passes; bug ships.

## Tester Analysis
The sampling-loop pattern itself is correct (this is the only test
where a tight `setTimeout(r, 16)` polling loop *is* the assertion, per
plan §2.2). The flaw is duration choice: 600ms is shorter than the
2500ms the same test budgets for the initial render to settle. Either
extend the window to ~3000ms, or pivot to an event-driven stop
condition: keep sampling until `scrollTop` has been stable to within
1px for N consecutive frames AND every mounted canvas reports
`complete === true`. That way a late-firing render that triggers a
late shift still has a chance to be captured.

## Reviewer-1 Verdict: BUG-A
**Agent type:** general-purpose
**Flake check:** N/A (deterministic timing-window analysis, not a run-level flake)
**Reasoning:** Sampling loop at `e2e/pdf-scroll-up-jitter.spec.ts:59` (`while (performance.now() - start < 600)`) is shorter than the same test's own 2500ms render-settle budget at L47. The regression class — late "measured-dimensions ready" signal causing a placeholder shrink + virtualizer scroll adjustment — can fire after 600ms on a slow CI worker, leaving `Math.min(...samples)` blind to the back-jump. The assertion at L77 would then pass while the bug ships, matching the mutation probe described in the finding.
**Suggested fix scope:** Replace fixed 600ms window with an event-driven stop (sample until `scrollTop` stable ±1px for N frames AND every mounted canvas reports `complete`), with a safety cap of ~3000ms.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** abandoned
**Commit:** —
**Notes:** Extended the sample window from 600ms to 3000ms in
`apps/rishi-electron/e2e/pdf-scroll-up-jitter.spec.ts:59` and bumped
`test.setTimeout(180000)` to absorb the extra 2.4s. Locally the test
never reaches the assertion: it hangs for the full 60s/90s/180s budgets
with the worker teardown timing out. Same hang reproduces against the
unmodified spec via stash check, indicating the launch/import/openBook
helper chain in this environment is the bottleneck, not the new
sampling window. No `error-context.md` trace beyond the bare timeout is
emitted (no `trace: 'on-first-retry'` artifact since retries=0). Rolling
back the spec change so the suite stays green; the original 600ms
blindspot is unchanged. Recommend: (a) tester to investigate
`e2e/helpers/electron-app` slowness on local dev or (b) re-attempt this
fix on CI where launch is presumably faster, with `test.setTimeout` set
just above `launch + import + 8500ms` empirically measured.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
