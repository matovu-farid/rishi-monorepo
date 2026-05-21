# Phase B Planner P8 — Infra + Misc Specs Plan

**Slice (10 specs):**

Infra (5):
- `apps/rishi-electron/e2e/auth.spec.ts`
- `apps/rishi-electron/e2e/import.spec.ts`
- `apps/rishi-electron/e2e/library.spec.ts`
- `apps/rishi-electron/e2e/smoke.spec.ts`
- `apps/rishi-electron/e2e/no-toolbar.spec.ts`

Misc (5):
- `apps/rishi-electron/e2e/mobi-global-page-counter.spec.ts`
- `apps/rishi-electron/e2e/scanner.spec.ts`
- `apps/rishi-electron/e2e/search.spec.ts`
- `apps/rishi-electron/e2e/tutorial.spec.ts`
- `apps/rishi-electron/e2e/window-split.spec.ts`

---

## 1. Skip List Across All Files

After reading all ten specs end-to-end, **zero** tests use `test.skip`,
`test.fixme`, `it.skip`, or `describe.skip`. Every test in this slice is
active and runnable. There is no parity gap to record on "tests opted-out
of CI" for this slice — contrast pilot (warm-restore specs were both
fully `.skip`).

Caveats that look like skips but aren't:

- `scanner.spec.ts:21` early-returns out of a `beforeEach` cleanup branch
  if no modal is open. This is conditional setup, not a skip of the test
  body. Tester should NOT flag.
- `tutorial.spec.ts:25-27` conditionally clicks "Maybe later" only if the
  welcome modal is visible. Same — conditional setup, not a skipped
  assertion. Do NOT flag as a skip.

---

## 2. Per-File Audit Checklist

Read pilot §2 first for the common anti-pattern vocabulary (timing
heuristics, tautological assertions, weak body locators, shared-Electron
fragility). Below is **only** what's specific to each file.

### 2.1 `auth.spec.ts` (3 tests, shared `beforeAll(launchApp)`)
- **Auth-surface is minimal.** No OAuth, no redirect handling, no deep
  link, no Redis polling. Tests only assert: Sign In link is visible,
  welcome modal reappears on localStorage clear, "Maybe later" dismisses
  + persists. The spec is **not** a coverage substitute for the
  deep-link auth flow described in `project_electron_deeplink_auth.md`
  / `feedback_redis_polling_auth.md`. **Parity gap** candidate —
  no test covers the desktop OAuth handoff at all.
- **L19, L28, L38, L43** — `waitForTimeout(300/1500)` after `reload()`
  / hash navigation. Replace with `expect(...).toBeVisible({ timeout })`
  auto-wait against a known landmark. **Practice violation**.
- **L20** — `text=Sign In` (case-sensitive) vs **L30** `text=Sign in`
  (lowercase 'i'). Two different selectors for the same intent. One is
  wrong or the UI exposes both. Inspect the rendered DOM to confirm
  which is canonical; if both render, flag as **practice violation**
  (selector ambiguity) and pick the role-based locator instead.
- **Shared `beforeAll(launchApp)`** — three tests mutating localStorage
  on one Electron instance. State leak between tests is plausible
  (test 3 clears localStorage, but earlier tests do too). Order-dependent.
  Compare to per-test `launchApp` pattern (pilot §3.2). **Practice violation**.
- **No assertion that auth state survives a reopen** of the Electron
  app. **Parity gap**.

### 2.2 `import.spec.ts` (6 tests, shared `beforeAll(launchApp)` + per-test `deleteAllBooks`)
- **L29-36, L39-46, L49-55** — Direct `page.evaluate(() => e.getPdfData(...))`
  calls hit the IPC parser **without** going through the dispatch path
  (`importBookViaOpenFile`). This is exactly the bug class pilot 011
  (and `azw3-real-import-routing.spec.ts`) was written to catch. The
  asserted `kind: 'pdf'` / `kind: 'epub'` / `kind: 'mobi'` is the
  parser's return value, NOT the dispatcher's `kind` decision. **Parity
  gap**: no per-format `*-real-import-routing` coverage for PDF or EPUB.
- **L34, L44, L54** — `toMatchObject({ kind: 'X' })` is a one-field
  assertion. Title, author, cover length, page count are unchecked.
  Weak parser-contract coverage. **Practice observation**.
- **L57-64** — `expect(['ok','warn']).toContain(result)` will pass for
  almost any output the IPC returns (only `'error'` would fail). This
  is barely a check. **Practice violation** (assertion too loose).
- **L66-78** — `copyFile + exists` round-trip leaves no leak (removeFile
  in same test), but uses a hard-coded `'/import-roundtrip.pdf'` filename
  under `getAppDataPath`. If two tests run in parallel against the same
  userDataDir, they'd collide — verify Playwright workers=1 here.
- **L80-92** — Only PDF import-persistence is tested. EPUB and MOBI
  import paths have no `getBooks()` round-trip. **Parity gap** vs.
  the three parser tests above.

### 2.3 `library.spec.ts` (5 tests, shared `beforeAll(launchApp)` + per-test cleanup)
- **L25-28** — `evaluate(() => window.location.hash = '#/')` then
  `waitForTimeout(500)`. Sets hash but does not await React route
  effect. **Practice violation**.
- **L45-46, L85-86, L106-107, L126-127** — `reload()` + `waitForTimeout(1500)`
  five times in this spec. Heavy reliance on timing. The grid-loaded
  signal (`[data-tour="book-grid"]` visible) is a stable wait target —
  use it instead.
- **List ordering** is asserted nowhere. The spec adds two books in
  `search filters book list by title` (L74-99) but never checks the
  display order matches insertion / title / recency. **Parity gap** —
  library-ordering contract is uncovered.
- **L51-58** — Locator chain `[data-tour="book-grid"] > div ... button`
  reaches into a sibling structure. If the grid is restructured to use
  `<li>` or `<a>` rows, this breaks. Borderline — would prefer
  `getByRole('button', { name: /Library Open Test/ })` if the
  accessible name is set. **Practice observation**.
- **L61-70** — Hand-rolled `Date.now()` polling loop in a 10s deadline.
  Replace with `expect.poll(() => ctx.pages().some(...))`. The current
  loop is non-fatal but uses raw `waitForTimeout(100)`. **Practice violation**.
- **L101-117** — Delete-via-right-click depends on a confirm button
  named exactly `"Delete"`. No confirmation modal is asserted — if
  prod adds a "Are you sure?" step, the test passes by coincidence
  (or fails opaquely). **Possible bug surface** in production code if
  the delete is non-confirmed (destructive action without confirmation
  is a UX violation; file in `practices-audit.md` if confirmed in code).

### 2.4 `smoke.spec.ts` (3 tests — sanity)
- **Do NOT over-audit.** Smoke is meant to be wide+shallow. Treat all
  three tests as one unit. Findings here are almost always wrong —
  prefer `practices-audit.md` over `findings/` for anything spotted.
- **L26-46** — IPC surface inventory tests `typeof === 'function'` on
  11 names. If a method is renamed, this catches it; if a method's
  signature changes, this misses it. By design — accept it as a
  smoke test, not a contract test.
- **No assertion that the boot is fast** (no timing budget). The
  current `toBeVisible()` defaults to 5s. Acceptable.
- **L21-24** — Empty-library copy strings ("No books yet",
  "drag and drop") are tightly coupled to copy. A copy change breaks
  smoke. **Practice observation** — pick `data-testid` instead.

### 2.5 `no-toolbar.spec.ts` (1 test — per-test `launchApp`)
- **L9** — `waitForTimeout(1500)` after `openBook`. Replace with
  `await bookPage.locator('iframe, canvas').first().waitFor({ state: 'visible' })`.
  **Practice violation**.
- **L10-11** — `count() === 0` for `[data-tour="reader-toolbar"]` is
  the right assertion shape (presence-negative). But the test asserts
  the *absence* of a selector — if `data-tour="reader-toolbar"` is
  renamed in prod, this test silently passes forever. Pair with a
  positive assertion (e.g., the menu-bar replacement is present).
  **Practice observation**, low severity.
- Test scope is one format (PDF). EPUB/MOBI/AZW3 reader windows could
  still ship a stray toolbar. **Parity gap**.

### 2.6 `mobi-global-page-counter.spec.ts` (1 test — per-test `launchApp`)
- **Best-written spec in the slice.** It documents the regression in
  the file header (L1-13), uses `expect.poll` with explicit timeouts
  and intervals (L65-70), caps iteration (L52), and asserts the
  fixture actually exercised the bug case (L85-88). Use as a
  reference for what good looks like.
- **L15** — `test.setTimeout(90000)` — large. Confirm via runtime
  whether the test routinely runs ≤30s; if so, lower the budget so
  a real regression (e.g. slow chapter blob loading) surfaces.
  **Practice observation**.
- **L25** — `[data-testid="azw3-page-counter"]` for a MOBI test. The
  shared component name is `azw3-` — internal coupling. If the
  AZW3/MOBI viewer is renamed, MOBI tests break. **Practice
  observation**.
- **L32** — `waitForTimeout(500)` "Settle initial measurement". The
  rest of the spec polls; this one bare wait is inconsistent. Replace
  with a poll on counter `data-current` being non-NaN. **Practice
  violation** (minor).
- **No back-direction test.** Prev-page from page N+1 should return
  to N, including across chapter boundaries. **Parity gap**.

### 2.7 `scanner.spec.ts` (3 tests — shared `beforeAll`)
- **L16-23** — `beforeEach` presses Escape, then conditionally clicks
  Cancel, then sets hash. Defensive cleanup is OK but the order
  (Escape → check → click → wait) hides race conditions. Replace
  with `closeAllModals()` helper. **Practice violation** (test infra).
- **L45** — `text=/Scanning/i` — regex on user-visible copy. Brittle.
  Prefer a `data-testid="scan-indicator"` if available; otherwise
  acknowledge the copy-coupling. **Practice observation**.
- **No assertion that scan results are surfaced** — only that the
  indicator appears. The full "scan → results list → import" path is
  uncovered. **Parity gap**.
- **No cancel-mid-scan test.** Cancel after scan completes ≠ cancel
  while scanning. The mid-scan cancel path is more bug-prone (file
  handles, IPC cleanup). **Parity gap**.

### 2.8 `search.spec.ts` (2 tests — shared `beforeAll(launchApp)` with shared imported book)
- **L17-22** — Book imported once in `beforeAll` is reused across
  tests. If test 1 mutates library state, test 2's `bookId` may still
  be valid but the underlying book row could be gone. Brittle.
  **Practice observation**.
- **L42-54** — `searchBookText` test only asserts `Array.isArray(r)`.
  An empty array passes. The search index could be totally broken
  and this test would still pass. **Practice violation** — strengthen
  to assert at least one match for a common stop-word against a fixture
  whose contents are known.
- **L46-50** — `try { ... } catch { return false }` swallows the
  exception. If the IPC throws, the assertion just reports
  `expect(false).toBe(true)` with no error context. Let the throw
  propagate so the failure message is useful. **Practice violation**.
- **No cross-format coverage** — only EPUB. PDF/MOBI/AZW3 search
  paths uncovered. **Parity gap**.

### 2.9 `tutorial.spec.ts` (4 tests — shared `beforeAll({ keepOnboarding: true })`)
- **Step-flow coverage is partial.** Tests cover: step 1 target,
  step 1 → 2 advance, skip, and persistence. **No test** that the
  tour completes all the way to the end (final step → completion).
  If a middle step is broken, tests pass. **Parity gap**.
- **L23-29** — `beforeEach` clears tour flags then handles the
  welcome modal. The conditional-click branch hides whether the
  welcome modal is *expected* in a given test. **Practice
  observation**.
- **L34, L41** — Regex `/1 of \d+/` / `/2 of \d+/`. Good — tolerant
  of total-step changes. Keep.
- **L48-49** — Asserts the `localStorage` flag string `'1'` literally.
  If prod switches to `'true'`, tests fail. Acceptable coupling
  (storage contract is internal). No action.
- **L52-58** — "completed tour does not relaunch" sets the flag then
  reloads; correct shape. But there's no test that an *interrupted*
  tour (closed mid-step) resumes correctly on reopen. **Parity gap**.
- **No test for the tour target highlighting / popper positioning.**
  Step assertions check copy visibility, not visual anchoring. Hard to
  test from Playwright — accept as a gap, document only.

### 2.10 `window-split.spec.ts` (3 tests — per-test `launchApp`)
- **L29, L48, L60** — Asserts `launched.app.windows().length === N`
  after fixed `waitForTimeout`s. If the open-book IPC is racy, a
  stray helper window or a delayed close could make this flake.
  Replace with `expect.poll(() => launched.app.windows().length).toBe(N)`.
  **Practice violation**.
- **L25-27 (first test)** — `waitForTimeout(1000)` × 2 between two
  `openBook` calls. If `openBook` resolves before the window is fully
  mounted (helper returns the Page eagerly), the count could be
  measured mid-mount. Check `openBook` implementation. **Possible
  bug** if helper resolves too early.
- **L35-52** — "same book twice does not duplicate windows" — good
  contract test. No assertion that the *existing* window is focused
  / raised, just that a second window isn't created. **Parity gap**.
- **L60-77** — Window identity test. Good. No assertion that
  `bookId` matches the **opened** book vs. some other id (only that
  the array contains a `book` identity with `bookId: a.id` — fine).
  No coverage of `windowIdentity` for closed-then-reopened windows.
  **Parity gap**.
- **No test for cross-window state sync** — if both library and book
  windows mutate book metadata, do they converge? Out of scope but
  flag in `parity-gaps.md`.

---

## 3. Tester Assignments

Three testers split the slice. ID ranges are non-overlapping, 15
each (5 per spec × spec-count cap from pilot §4.2).

### B-T8 — Infra heavy (auth, import, library) → IDs **B101-B115**
- Files: `auth.spec.ts`, `import.spec.ts`, `library.spec.ts`.
- Focus: shared-state leakage (all three use `beforeAll(launchApp)`),
  dispatch-vs-parser bypass (import), list-ordering & delete-confirm
  (library), and the OAuth-coverage gap (auth).
- Per-spec finding cap: 5 (pilot §4.2). Likely outputs: 2-3 findings,
  3-5 entries in `parity-gaps.md`, 4-6 entries in `practices-audit.md`.

### B-T9 — Smoke + misc-light (smoke, no-toolbar, mobi-global-page-counter, scanner) → IDs **B116-B130**
- Files: `smoke.spec.ts`, `no-toolbar.spec.ts`,
  `mobi-global-page-counter.spec.ts`, `scanner.spec.ts`.
- Focus: do NOT over-audit smoke; verify the well-written MOBI counter
  spec actually catches the regression (mutation check); scanner's
  mid-scan / results paths.
- Likely outputs: 0-1 findings, 4-5 parity-gap entries, 4-6 practice
  entries. The MOBI counter spec is the most likely source of a
  real prod bug *if* the polling pattern reveals a race.

### B-T10 — Heavy-misc (search, tutorial, window-split) → IDs **B131-B145**
- Files: `search.spec.ts`, `tutorial.spec.ts`, `window-split.spec.ts`.
- Focus: search's exception-swallowing + weak assertions (most likely
  to hide a real prod bug); tutorial's step-flow gaps; window-split's
  race-prone count assertions.
- Likely outputs: 1-2 findings (search-index could be silently broken),
  4-6 parity gaps, 3-5 practice entries.

---

## 4. Test Commands

### Build prerequisite (mandatory before any e2e run)

```bash
pnpm --filter rishi-electron build
```

The e2e harness resolves `../../out/main/index.js` (pilot §5.1). Without
a current build, every spec below will fail to launch the Electron main
process. Re-run after touching `src/main/**`.

### Per-spec runs (cwd `apps/rishi-electron`)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron

# B-T8
pnpm test:e2e e2e/auth.spec.ts
pnpm test:e2e e2e/import.spec.ts
pnpm test:e2e e2e/library.spec.ts

# B-T9
pnpm test:e2e e2e/smoke.spec.ts
pnpm test:e2e e2e/no-toolbar.spec.ts
pnpm test:e2e e2e/mobi-global-page-counter.spec.ts
pnpm test:e2e e2e/scanner.spec.ts

# B-T10
pnpm test:e2e e2e/search.spec.ts
pnpm test:e2e e2e/tutorial.spec.ts
pnpm test:e2e e2e/window-split.spec.ts
```

### Single test by name

```bash
pnpm test:e2e e2e/library.spec.ts -g "imported book appears in library"
```

### Flake check (≥3 runs, per pilot §5.6)

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e <spec> -g "<test name>" || echo "run $i: FAIL"; done
```

### Discovery dry-run

```bash
pnpm test:e2e --list e2e/window-split.spec.ts
```

---

## Notes for testers

- Finding template + rules: see pilot plan §4. Reviewer-1 alternation
  by odd/even trailing digit (pilot §4.4) applies to IDs B101-B145.
- Most output should land in `parity-gaps.md` and `practices-audit.md`.
  Zero findings is a valid outcome per tester.
- Do not file findings against `smoke.spec.ts` unless you can show a
  production code path it would catch and currently doesn't.
