---
id: B095
spec: e2e/tts-page-navigation.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
Three BUG-marked tests use large arbitrary `waitForTimeout` instead of
polling the observable state they care about. These waits mask races rather
than expose them, and they trade real-time flakiness for elapsed-time bloat.
- L646: `await bookPage.waitForTimeout(300)` — "Give the stale
  loadAndPlayAudio time to (incorrectly) call play."
- L1010: `await bookPage.waitForTimeout(6000)` — wait for player to settle
  after a Next-page click in test `T1: Play -> Next via UI button -> Play
  button recovers (BUG)`.
- L1194: `await bookPage.waitForTimeout(2000)` — "Wait 2s for any unwanted
  nav to materialize" in `T2: Stuck-loop reproducer (BUG)`.

Each of these waits is the central oracle of the test. If the bug being
guarded against takes 6001ms to manifest, the test still passes. If the
fixture happens to settle in 100ms on a fast machine, the test still spends
6s wall-clock for no reason. The correct shape is `expect.poll(() =>
readPlayerSnapshot(bookPage), { timeout: ... }).toMatchObject(...)` plus a
deadline-based negative assertion using `expect.poll(...).toBe(false)` over
a short window, or `await bookPage.waitForFunction(...)` with a tight
`timeout`.

## Reproduction
- Test file: `apps/rishi-electron/e2e/tts-page-navigation.spec.ts`
  - L640-672 (`audio.play() was called for off-page CFI(s)` test)
  - L1004-1058 (`T1: Play -> Next via UI button -> Play button recovers`)
  - L1187-1213 (`T2: Stuck-loop reproducer`)
- Failing assertion: post-wait assertions at L662-665, L1012-1017,
  L1196-1212. None of them poll; they snapshot once after the static wait.
- How to run: `pnpm test:e2e e2e/tts-page-navigation.spec.ts -g "Stuck-loop"`
  (and repeat 3-5 times to observe wall-clock cost).

## Tester Analysis
The BUG-marked tests are exactly the ones that must survive future
state-machine refactors. Static `waitForTimeout` is the worst possible
oracle for that purpose: it picks an arbitrary point in time and asserts
the post-condition, with no monotonic guarantee that the post-condition
either (a) holds stably or (b) was the actual settle-state of the system.
Concretely:

- L1010 + L1012-L1017 (T1): if a regression introduces a 7s settle time
  for `playingState`, the snapshot at L1012 reads an intermediate state
  (`loading` or `pageNavigating`), and the conditional at L1021 then
  clicks Play UI — which happens to also fix the state. The test passes
  while the bug is present. The fix is to assert the post-nav state with
  `expect.poll(...)` against a stable window (e.g., state stays
  `playing` for ≥250ms continuously).
- L1194 + L1196-L1212 (T2): the bug-detection wait *positively asserts*
  the absence of a state change. The right shape for a "no-op happens
  within N seconds" assertion is `await expect.poll(() => readPageCfi(),
  { timeout: 2000 }).toBe(pageBefore)` — which polls and fails fast on
  *any* change. The current snapshot-once shape will pass if the unwanted
  nav happens at t=2001ms.
- L646: comparable issue; the assertion at L662 reads `playLog` after a
  fixed 300ms. A bleed at t=350ms would not be caught.

The fact that these tests are explicitly marked `(BUG)` and target
specific user complaints makes the masking risk especially material: these
are the regression guards that must work.

Recommendation: replace each `waitForTimeout(N)` with
`waitForFunction`/`expect.poll` against the observable that the test
actually cares about, with the same outer deadline. For "no change
happens" assertions, use `expect.poll` over the full window with a
post-window stability check.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Tester Rebuttal: ACCEPT-REJECTION | REBUT

## Tiebreaker Verdict: CONFIRM | REJECT

## Fix Plan
status: fixed
commit: 7dcdc8b5
notes: Replaced the three flagged `waitForTimeout` calls in
`tts-page-navigation.spec.ts` with event-based waits.
- L646 (bleed window after canplay-gate release): `waitForFunction` polls
  `__rishiPlayLog` and resolves the moment an off-page audio.play() entry
  appears (300ms timeout — timeout means clean window).
- L1010 (post-Next settle): `waitForFunction` polls `playingState` until
  it leaves the transient `loading` / `pageNavigating` set, with an 8s
  deadline. The downstream "auto-resume vs. recovery click" branching is
  unchanged.
- L1194 (no-unwanted-nav window): `waitForFunction` polls
  `currentParagraphs[0].index` and fails fast on any non-null change from
  `pageBefore`, with a 2s timeout (timeout means page held steady).
The `null → non-null` boundary in the L1194 case is treated as
"page populated", not "navigation", to avoid spurious failures while the
machine re-publishes paragraphs. Typecheck green; e2e not run per env note.

## Code Review

## Coder Rebuttal

## Code-Review Tiebreaker

## Mutation Check

## Final Verdict

## Reviewer-1 Verdict: BUG-B
**Agent type:** team-reviewer
**Flake check:** N/A (static analysis of test oracle shape)
**Reasoning:** Confirmed at L646, L1010, L1194 of apps/rishi-electron/e2e/tts-page-navigation.spec.ts. Each waitForTimeout is followed by a single snapshot-style assertion (L662-665, L1012-1017, L1196-1212) with no polling — exactly the anti-pattern the finding describes. L1194 is the most material: a "no unwanted nav happens within 2s" assertion is structurally wrong as snapshot-after-wait; it cannot fail-fast and gives no margin past 2000ms. L1010's 6000ms wait + branching conditional at L1021 can let an intermediate state (loading/pageNavigating) silently satisfy the test by triggering the recovery click. These are BUG-marked regression guards, so masking risk is material, but they are test-quality issues, not product bugs — classify as B (important, not ship-blocking).
**Suggested fix scope:** Replace each waitForTimeout with expect.poll/waitForFunction against the observable; for the negative assertion at L1194, poll currentParagraphs[0].index over the 2s window and fail on any change.
