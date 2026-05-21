---
id: B132
spec: e2e/window-split.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: general-purpose
dispatches_used: 1
---

## Bug Summary
All three tests in `window-split.spec.ts` assert
`launched.app.windows().length === N` (where N ∈ {2,3}) immediately after
a fixed `waitForTimeout(800|1000)`. The window count is a snapshot at a
single instant — a stray helper window that opens momentarily, a slow
preload that hasn't yet registered the window, or a focus/show race in
`BrowserWindow` creation will produce a non-deterministic count. More
importantly, if `openBook` resolves before the new `BrowserWindow` has
emitted `ready-to-show` (likely, given the helper just sends an IPC), the
count assertion can pass while the window is still mid-mount — masking a
real "duplicate window" bug where a second window is created N+1 ms later.

## Reproduction
- Test file: `apps/rishi-electron/e2e/window-split.spec.ts`
  - lines `24-29` (two books → expect 3 windows)
  - lines `43-48` (same book twice → expect 2 windows)
  - lines `58-60` (open one book before identity check)
- Failing assertion (representative): `expect(wins.length).toBe(3)` at L29
- How to run:
  ```
  cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
  pnpm --filter rishi-electron build
  for i in 1 2 3 4 5; do pnpm test:e2e e2e/window-split.spec.ts || echo "run $i FAIL"; done
  ```

## Tester Analysis
The "same book twice does not duplicate windows" test (L35-52) is the
canonical contract test for the dedup-by-bookId rule in the main process
(likely `src/main/window/openBookWindow.ts` or similar). It currently:

1. **Has no assertion that the existing window is focused/raised.** Plan
   §2.10 calls this out — when a user re-opens an already-open book, the
   expected UX is "raise existing", not "no-op silently". A regression
   that no-ops the second call entirely (no raise, no focus) passes this
   test.
2. **Uses a snapshot count after a fixed timeout.** Replace with
   `await expect.poll(() => launched.app.windows().length).toBe(2)`, then
   add a *negative* poll: assert the count *stays* at 2 for ≥500ms (i.e.
   no late-arriving duplicate). A naive `toBe(2)` immediately after IPC
   round-trip can pass while the duplicate window is still being created.
3. **`openBook` helper return semantics are not pinned.** If the helper
   resolves on IPC ack rather than on `BrowserWindow.once('ready-to-show')`,
   the test is racy against any production code that creates the window
   asynchronously (which Electron's `new BrowserWindow()` is, via
   `webContents` load).

Production paths to inspect: the main-process handler for "open book"
IPC, and whatever map dedupes by bookId. A real bug here (e.g. a missing
`.has(bookId)` short-circuit, or a race where two near-simultaneous
opens both miss the dedup map) would not be caught reliably.

## Reviewer-1 Verdict: B
**Agent type:** general-purpose
**Flake check:** N/A (static review — flake hypothesis is the finding itself; no run performed)
**Reasoning:** Three independent sensitivity gaps confirmed against code: (1) `windowManager.test.ts:45-53` asserts only object-identity + factory-call-count for `openBook`, not `existing.focus()` — contrast with `openLibrary` (L33) and `openSettings` (L91) which DO assert `fake.focus` was called. Production at `windowManager.ts:54` does call `existing.focus()`, so a regression that drops the raise would silently pass both the unit test and the e2e same-book-twice test (L35-52). (2) The e2e helper `openBook` at `electron-app.ts:213-223` polls `ctx.pages().find((p) => p.url().includes('/books/${bookId}'))` and returns on first match, so a late-arriving duplicate window for the same bookId is structurally invisible to the helper. (3) `expect(wins.length).toBe(N)` after a fixed `waitForTimeout(800|1000)` (L25-29, L44-48) is a snapshot — Playwright's `expect.poll(...).toBe(N)` followed by a "stays N for ≥500ms" assertion is the correct pattern for "no duplicate appears late". The `window:openBook` IPC handler (`index.ts:235`) returns sync on the WindowManager call, before `ready-to-show`, so the helper resolves before the BrowserWindow has fully materialized — narrow window but real.
**Suggested fix scope:** Add a `existing.focus()` assertion to the openBook re-open unit test, and in the e2e tighten with `expect.poll(...).toBe(N)` + a follow-up stability check that count stays at N for ~500ms; optionally pin `openBook` helper semantics to wait for `ready-to-show` instead of first URL match.

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
<append after wave 7; "Production fix reverted at <SHA-or-stash-id>; test failed as expected. Restored; test passes.">

## Final Verdict
<commit SHA + verified test pass + mutation check passed>
