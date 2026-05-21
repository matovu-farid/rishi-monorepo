---
id: B020
spec: e2e/epub-cache-no-flash.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: feature-dev:code-reviewer
dispatches_used: 1
---

## Bug Summary
The high-frequency loader poller injected at L67–107 runs entirely inside
a single `page.evaluate(() => { ... })` block and self-schedules via
`requestAnimationFrame`. If any line inside `tick()` throws (e.g.
`getComputedStyle` on a node detached mid-frame, or a mutation that
nulls out `parentElement` between `c.textContent` and `visibleToUser`),
the rAF chain dies silently. `w.__loaderEverSeen` then remains `false`
for the rest of the run, and the L114–125 readback returns `seen === false`,
causing the assertion `expect(seen, '...').toBe(false)` to pass —
the test reports "no flash detected" precisely because the detector
crashed. This is a false-negative shaped exactly like a true pass.

Although the spec is currently `test.skip(...)` (L28, Phase-3 window
split), it is filed in active scope because the comment at L28–34
explicitly anticipates un-skipping after cache rework; the bug will
ship the moment the skip is removed.

## Reproduction
- Test file: `apps/rishi-electron/e2e/epub-cache-no-flash.spec.ts` lines `L67-L125`
- Mechanism: silent rAF chain termination on any thrown error inside the
  injected `tick()` function. Particular hotspots:
  - L88 `window.getComputedStyle(node)` on a node removed since L86 read
  - L98 `c.textContent` on a node whose parent was unmounted
- How to run (when un-skipped): `pnpm test:e2e e2e/epub-cache-no-flash.spec.ts`

## Tester Analysis
The poller is meant to detect a brief visible loader between cache hit
and iframe mount. Any false-negative path here defeats the regression
guarantee. Two minimal hardenings:
1. Wrap `tick()` in `try { ... } catch (e) { w.__loaderError = String(e); }`
   and rethrow from the L114 readback if `__loaderError` is set.
2. Track `w.__tickCount` and assert it grew during the reopen window — if
   the count is suspiciously low, the rAF chain died.

Production-code adjacent: the test exercises
`src/renderer/src/services/reader-cache/epub-cache.ts` (verified to
expose `has()` and `stats()` symmetrically with `pdf-cache.ts`, so the
plan's §2.1 concern about a missing surface does not apply here). The
finding is purely about detector robustness inside the spec.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (spec is `test.skip` at L28; no current CI signal)
**Reasoning:** Code at L67-107 confirms rAF self-scheduling `tick()` with no try/catch. L88 `getComputedStyle` walking `parentElement` chain and L97-98 `c.textContent` reads on live `querySelectorAll('p')` results are genuine throw hotspots during a reopen race where the DOM is in flux. A throw inside `tick()` would terminate the rAF chain, leaving `__loaderEverSeen=false`, and the L114-125 readback would erroneously report "no flash." The asymmetry — detector crash looks identical to test pass — is a real correctness gap. Not a BUG (spec is skipped, no live false-negative shipping), but a clear robustness defect that lands the instant L28 is un-skipped per the comment's own intent. Classify B: real defect, low-to-moderate severity, scoped to test infrastructure rather than production code.
**Suggested fix scope:** Wrap `tick()` in try/catch storing `w.__loaderError`, and add a `w.__tickCount` invariant the readback asserts grew during the reopen window.

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict
