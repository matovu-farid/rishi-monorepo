# Practices audit — B-T10 (search, tutorial, window-split)

Lower-severity test-quality issues; not production-bug findings.

## search.spec.ts

- **L34** — `waitForTimeout(300)` after hash navigation. Replace with an
  auto-wait against a known landmark (e.g. `await expect(input).toBeVisible()`).
  Timing-heuristic anti-pattern.

- **L35** — `input[placeholder*="Search"]` is a copy-coupled selector.
  Switch to `getByRole('searchbox')` or `data-testid="library-search"`.

- **L46-50** — `try/catch` swallows the exception (also called out in
  finding B131). Let the IPC throw propagate; assert positively on
  `r.length > 0` against a known-good fixture token.

- **Shared `beforeAll(launchApp)` + shared `bookId` across tests.** Plan
  §2.8. Test 1 mutates library input state; test 2 depends on `bookId`
  surviving. State leak is plausible. Prefer per-test `launchApp` or at
  minimum re-fetch bookId in each test.

## tutorial.spec.ts

- **L22, L28, L57** — Three `waitForTimeout(1500|800|800)` calls after
  reload/click. Replace with `await expect(<tour-popper>).toBeVisible()`
  / `.toHaveCount(0)` polls. The current shape works but is slow and
  hides ordering bugs.

- **L23-29 `beforeEach` conditional welcome-modal click.** Plan §2.9.
  The conditional hides whether the modal is *expected* in each test;
  if a regression stops showing the welcome modal, the `if` silently
  no-ops and the test still appears to pass its setup. Make the
  expectation explicit per-test, or factor a `dismissWelcomeIfPresent()`
  helper that logs which branch ran.

- **L39, L46** — `text=Next` / `text=Skip` are bare text selectors that
  match anywhere in the DOM. Scope to the tour popper:
  `app.page.locator('[data-tour-popper] >> text=Next')` (or whatever the
  popper wrapper is). Otherwise an unrelated future "Next" button
  collides.

- **`keepOnboarding: true` shared across all 4 tests.** Single Electron
  instance + localStorage manipulation = order-dependent state. Compare
  to per-test `launchApp` pattern (pilot §3.2).

## window-split.spec.ts

- **L25-27, L44-46, L59** — Five `waitForTimeout(800|1000)` calls
  guarding window count. Replace with
  `await expect.poll(() => launched.app.windows().length, { timeout: 5000 }).toBe(N)`,
  per plan §2.10. Also referenced in finding B132.

- **L57** — `importBook(launched.page, { fixturePath: PDF_FIXTURE, kind: 'pdf' })`
  with no `title`. Other tests pass a title; this one doesn't. Inconsistent.
  Either rely on the helper default or make titles consistent so failures
  print informative book labels.

- **L60-68** — `Promise.all(allWins.map(p => p.evaluate(...)))` does not
  guard against pages that have unloaded mid-test. If a window closes
  during the map, `evaluate` rejects and the whole `Promise.all` fails
  opaquely. Use `Promise.allSettled` and filter, or take a snapshot of
  identities up front.

- **Helper `openBook` return semantics undocumented.** All three tests
  depend on `openBook` resolving *after* the new window is fully mounted.
  Verify in `e2e/helpers/electron-app.ts` that `openBook` awaits
  `app.waitForEvent('window')` + `page.waitForLoadState`, not just the
  IPC ack. If it doesn't, every count assertion in this spec is racy by
  construction.

## Cross-spec

- **No flake-check evidence.** None of the three specs have been
  exercised under the pilot §5.6 "≥3 reruns" loop. Window-split is the
  prime candidate (window-count races); recommend running 5× before
  closing this audit cycle.

- **No tagging.** None of these specs use `test.describe.configure({
  mode: 'serial' })` or `test.slow()`, yet all rely on shared Electron
  state. Either annotate as serial explicitly or migrate to per-test
  launches.
