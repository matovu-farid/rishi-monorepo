---
id: B053
spec: e2e/pdf-scroll-up-jitter.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
The jitter assertion uses a flat 80px threshold (L77). If the original
bug magnitude was substantially larger (e.g. an h-screen placeholder
shrinking to ~600px page height = a ~200px+ shift), a partial fix or
regression that reduces — but does not eliminate — the jitter to,
say, ~90px would slip past this test while still being clearly
visible to users. The threshold is also untied to any observable
upper bound (frame height / line height / page height). It encodes
"the current fix is well below 80" rather than "the user should never
see more than X".

## Reproduction
- Test file: `apps/rishi-electron/e2e/pdf-scroll-up-jitter.spec.ts` lines `74-77`
- Failing assertion (currently passing; threshold semantically loose):
  ```ts
  const backJump = settled - lowestSample
  expect(backJump).toBeLessThan(80)
  ```
- How to run:
  ```bash
  cd apps/rishi-electron
  pnpm test:e2e e2e/pdf-scroll-up-jitter.spec.ts
  ```
- Mutation probe: introduce a 70px placeholder/real-height mismatch on
  the page above (set initial placeholder = real height - 70px). User
  sees a perceptible flicker; this test passes (70 < 80).

## Tester Analysis
The plan flags this directly: "If the original bug was 200px and the
fix overshoots to 90px, this test misses a partial regression."
Threshold choice for a "user shouldn't see jitter" assertion should
either be (a) much tighter — single-digit px, because any visible
shift is the bug — or (b) tied to a meaningful unit (e.g. line-height
of the rendered text in this fixture) with a justification comment.
The current 80 reads as "passes today, leaves headroom for noise"
which is exactly the regression-masking failure mode the audit phase
is told to flag. Recommended: tighten to e.g. `<8` (sub-line-height)
and re-run flake check; if flaky, instrument the source of the noise
rather than relaxing the bar.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
**Status:** fixed
**Commit:** df931eced60df21545db267b3ce16a06d8371ed6
**Notes:** Tightened the back-jump tolerance from 80px to 8px (named `JITTER_TOLERANCE_PX`) with an inline justification — the original bug class was ~200px (h-screen → page-height shrink), so any sub-line-height shift is the user-observable bug. Comment explicitly tells future maintainers to instrument noise sources rather than relax the bound, per tester guidance. Coordinated with B051 (same spec file, separate commits — B051 first, then B053).
**E2E mutation check:** env-blocked (sandbox teardown timeout); typecheck passes. Tester flagged tightening *might* flake in CI; if it does, the failure surfaces the noise source (which is the explicit accepted trade-off in the finding).

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

## Reviewer-1 Verdict: B
**Agent type:** team-reviewer
**Flake check:** N/A (static review; no test run performed — tester explicitly warns tightening to <8 may flake CI)
**Reasoning:** Spec L11-27 + L69-77 documents the original jitter as an h-screen→~600px shrink (200px+ class), and the assertion at L77 (`toBeLessThan(80)`) admits a ~70px residual jitter without failing — exactly the partial-regression gap. Not a runtime bug; it is a test-sensitivity gap that masks future regressions. Threshold is also untethered from any user-visible unit (line-height/page-height).
**Suggested fix scope:** Tighten threshold to a line-height-derived bound (or single-digit px) with a justifying comment; if flake emerges, instrument the noise source rather than relax.
