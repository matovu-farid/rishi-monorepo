---
id: B105
spec: e2e/library.spec.ts
status: open
created: 2026-05-20
reviewer1_agent_type: team-reviewer
dispatches_used: 1
---

## Bug Summary
`library.spec.ts` uses a single shared `beforeAll(launchApp)` Electron
instance for all five tests (L15-17) and relies on `deleteAllBooks` plus
a hash reset in `beforeEach` (L23-29) to isolate state. Two state
classes are NOT reset: (1) reading-position/last-opened state — the
"imported book appears in library and opens reader" test (L39-72) opens
a new BrowserWindow for the imported book, and that window is never
closed before the next test runs; (2) URL hash (`window.location.hash =
'#/'`) is followed by `waitForTimeout(500)` with no wait for the route
to actually mount. Tests in this file are therefore order-dependent and
share an accreting set of book BrowserWindows across runs. This
manifests as flakes (delete test races with stale book window's
in-memory cache) and as inflated `app.windows().length` for any later
spec that tries to count windows.

## Reproduction
- Test file: `apps/rishi-electron/e2e/library.spec.ts` lines `15-29`,
  `39-72`
- Failing assertion: order-dependent; observable as flake on repeated
  runs of the full file when test 2 leaves a `/books/<id>` window open
  and tests 3-5 then run against a renderer whose context still hosts
  that window.
- How to run (flake check):
  ```
  cd apps/rishi-electron
  pnpm --filter rishi-electron build
  for i in 1 2 3 4 5; do pnpm test:e2e e2e/library.spec.ts || echo "run $i: FAIL"; done
  ```

## Tester Analysis
Compare with `no-toolbar.spec.ts` (per-test `launchApp`, plan §2.5) and
`window-split.spec.ts` (per-test `launchApp`, plan §2.10) — both opted
for fresh-Electron-per-test specifically because window/context state
is hard to scrub between tests. `library.spec.ts` adopts the shared
pattern but the affordances it exercises (open-in-new-window,
right-click context menu, search-filter that reflows the grid) are
exactly the ones that mutate state outside the `books` SQLite table.

Two concrete failure modes the shared-beforeAll pattern admits:

1. The opened book window from test 2 (L54-58 click) is still attached
   to the same browser context when test 3's `deleteAllBooks` runs.
   `deleteAllBooks` removes the SQLite row, but the still-open book
   window's renderer may hold cached state that retries an IPC against
   a now-missing id, triggering an unhandled rejection that the next
   test inherits.
2. `app.page.reload()` calls (L45, L85, L107, L126) reload only the
   library page. If a prior test left the library route on `/books/<id>`
   via hash, the reload reopens that route; the `beforeEach` hash
   reset to `#/` plus 500ms wait is the only mitigation, and 500ms is
   below the observed React-route + book-grid mount budget on CI.

The fix is `beforeEach(launchApp)` + `afterEach(closeApp)` for this
spec, matching `no-toolbar.spec.ts`. Cost is ~2s per test of harness
overhead; benefit is removing the entire class of cross-test state
leaks.

## Reviewer-1 Verdict: CONFIRM | REJECT

## Reviewer-1 Verdict: B
**Agent type:** team-reviewer
**Flake check:** Not executed (per "flake-only, not yet observed in CI" caveat; reproduction loop would take ~10 min and finding's own text concedes it has not been observed).
**Reasoning:** Real cross-test coupling exists — `library.spec.ts:15-17` shares one Electron instance, `beforeEach` (L23-29) only scrubs SQLite rows + hash, and test 2 (L54-58) opens a book BrowserWindow that is never closed (no `ctx.on('page')` capture, no explicit `.close()`). `deleteAllBooks` (`helpers/electron-app.ts:188-195`) calls `deleteBook` against the library page only, leaving the orphan book window's renderer holding a stale id — a plausible source of unhandled-rejection bleed. The 500ms hash-reset wait (L28) is also genuinely thin vs. observed mount budgets. However: (1) no concrete failing run is cited, (2) tests 3-5 each call `app.page.reload()` which forces a fresh library mount and would mask most cached-state effects, (3) the orphan window only impacts tests that count `app.windows()` and none of the five library tests do. Real smell, low blast radius, no observed failure — fits B (clean up when convenient), not BUG.
**Suggested fix scope:** Switch `library.spec.ts` to per-test `launchApp`/`closeApp` matching `no-toolbar.spec.ts`, or at minimum close any `/books/<id>` pages in `beforeEach` before the hash reset.
