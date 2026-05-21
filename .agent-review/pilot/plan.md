# Pilot Plan — Warm-Restore Test Review

**Pilot scope (read-only for testers):**

- `apps/rishi-electron/e2e/pdf-warm-restore.spec.ts`
- `apps/rishi-electron/e2e/epub-warm-restore.spec.ts`
- `apps/rishi-electron/e2e/azw3-real-import-routing.spec.ts` (warm-restore-relevant tests only)
- `apps/rishi-electron/e2e/mobi.spec.ts` (warm-restore-relevant tests only)
- `apps/rishi-electron/src/renderer/src/stores/pdfStore.test.ts`
- `apps/rishi-electron/src/renderer/src/stores/epubStore.test.ts`
- `apps/rishi-electron/src/main/ipc/__tests__/formats-mobi.test.ts`
- Production targets these tests exercise (discover from imports):
  `src/renderer/src/stores/pdfStore.ts`, `src/renderer/src/stores/epubStore.ts`,
  `src/renderer/src/services/reader-cache/{cache,pdf-cache,epub-cache}.ts`,
  `src/main/ipc/formats.ts`, `src/main/ipc/books.ts` (`books:updateLocation`, `saveBook`),
  `e2e/helpers/electron-app.ts`.

**Surprises uncovered while reading the slice (testers please note):**

1. **Both warm-restore e2e specs are `test.skip(...)`.** `pdf-warm-restore.spec.ts:33`
   and `epub-warm-restore.spec.ts:69` are skipped pending Phase-3 (per-window) cache
   rework. They cannot currently produce production-bug findings — they are
   parity/coverage **gaps** until un-skipped. Treat this as the dominant parity
   gap for the pilot, not as bug source material.
2. **`pdfStore.test.ts` and `epubStore.test.ts` do NOT test restore at all.**
   They cover unit-level reducer behavior (page math, theme, reset). The
   "warm-restore" surface area lives in the e2e layer and the `reader-cache`
   service. Beware findings that pretend store unit tests cover restore.
3. **MOBI has no warm-restore e2e at all.** `mobi.spec.ts` only covers
   first-open render and crash-safety on a bogus id. The MOBI unit suite
   (`formats-mobi.test.ts`) is parse-only; nothing exercises persistence.
4. **AZW3's warm-restore surface is uncovered.** `azw3-real-import-routing.spec.ts`
   tests the import-routing bug (kind=azw3 not mobi); it does not exercise
   reopen-after-close at all. No AZW3 unit counterpart for the IPC paths exists.
5. **Persistence already has a working PDF spec elsewhere** (`pdf-persistence.spec.ts`),
   so PDF has both the LRU-cache angle (skipped) and the location-restore angle
   (live). EPUB only has the LRU-cache angle (skipped) — no live EPUB equivalent
   of `pdf-persistence.spec.ts`.

---

## 1. Parity Matrix

Capabilities below are warm-restore-related — i.e., the set of "did the app
remember where I was?" behaviors. Cells are based ONLY on what is currently
covered by an active (non-skipped) test in this slice or its referenced
production code.

| Capability | PDF | EPUB | MOBI | AZW3 |
|---|---|---|---|---|
| Cold open → reader mounts without ErrorBoundary | ✗ no test (only inside skipped `pdf-warm-restore.spec.ts`) | ✓ tested (`epub-first-open.spec.ts`, referenced) | ✓ tested (`mobi.spec.ts` "MOBI book opens and renders") | ✓ tested (`azw3-real-import-routing.spec.ts` asserts iframe visible + `src=blob:`) |
| In-session reopen hits a warm-restore cache (LRU) | ✗ skipped (`pdf-warm-restore.spec.ts:33`) | ✗ skipped (`epub-warm-restore.spec.ts:69`) | ✗ no test, no production cache | ✗ no test, no production cache |
| Location persisted on close, restored on reopen (page index) | ✓ tested elsewhere (`pdf-persistence.spec.ts`) — NOT in pilot scope but referenced for parity | ✗ no test in pilot scope | ✗ no test | ✗ no test |
| Sub-page scroll offset persisted (mid-page restore) | ✓ tested elsewhere (`pdf-scroll-position.spec.ts`) — for reference | N/A (EPUB uses CFI, not scroll px) | N/A | N/A |
| CFI / chapter location restored after reopen | N/A | ✗ no test in pilot scope (epubStore unit test only asserts setter parity) | ✗ no test (MOBI is chapter-indexed; `parseMobiChapters` parses but no reopen test) | ✗ no test |
| Recently-opened library ordering after reopen | ✗ no test in slice (search returns no `recently_opened` hits) | ✗ no test | ✗ no test | ✗ no test |
| ErrorBoundary fallback absent after reopen | ✗ asserted inside skipped tests only | ✗ asserted inside skipped tests only | ✗ not asserted | ✗ not asserted |
| Cache stats (`__readerCache.<fmt>.stats()`) hits on reopen | ✗ no diagnostic exposed for `pdf` (`pdf-cache.ts` exposes it; no test consumes) | ✗ skipped — would assert hits>0, misses=0 | N/A (no cache) | N/A (no cache) |
| TTS resume position after reopen | ✗ no test | ✗ no test | ✗ no test | ✗ no test |
| Reader route resolves to the correct viewer (kind→view dispatch) | ✓ implicit (PDF route covered by other specs) | ✓ implicit | ✓ implicit | ✓ tested (`azw3-real-import-routing.spec.ts` — explicitly asserts iframe is `src=blob:` not `srcdoc`) |
| Import via OS open-file (real dispatch) | ✗ no test | ✗ no test | ✗ no test (`mobi.spec.ts` uses `importBook` helper which bypasses dispatch) | ✓ tested (`azw3-real-import-routing.spec.ts`) |

> ✓ = covered by an active assertion; ✗ = not tested or test is `.skip`;
> N/A = capability doesn't apply to that format.

---

## 2. Per-Spec Audit Checklist

### 2.1 `e2e/pdf-warm-restore.spec.ts`

- **L33** — Entire suite is `test.skip(...)`. The skip rationale ("Phase 3 window
  split") is plausible but un-cited. Look for: is there a tracking task, a TODO,
  or a follow-up plan referenced? Currently no link. **Parity gap** (skipped
  warm-restore behavior), not a bug per se — record in `parity-gaps.md`.
- **L48-49, L54, L59** — Three `waitForTimeout(3000 / 1000 / 2000)` calls. These
  are brittle/timing-based; Playwright auto-wait (`expect(...).toBeVisible({ timeout })`)
  is already used adjacent. **Practice violation** if/when un-skipped — record in
  `practices-audit.md`.
- **L50-51** — Asserts on `canvas.react-pdf__Page__canvas` — an internal CSS class
  exposed by `react-pdf`. Is this an implementation-detail assertion? Compare
  against EPUB spec (`iframe` is a stable contract). Borderline; flag in
  `practices-audit.md` if concerned.
- **No assertion that the cache was actually hit on reopen.** Compare to
  `epub-warm-restore.spec.ts:109-111` which asserts
  `stats.hits > 0 && stats.misses === 0`. The PDF cache exposes the same
  diagnostic (`pdf-cache.ts`), but the spec doesn't consume it. **Parity gap**:
  PDF cache assertion is weaker than EPUB equivalent.
- **No location/page-index restore assertion.** This spec is specifically about
  the LRU cache; restore-by-location is in `pdf-persistence.spec.ts`. Not a bug
  by itself but document the boundary.

### 2.2 `e2e/epub-warm-restore.spec.ts`

- **L69** — `test.skip(...)` for the same Phase-3 reason. **Parity gap** —
  record in `parity-gaps.md`.
- **L88-89, L92, L99, L106** — Multiple `waitForTimeout(500 / 500 / 500)` calls
  with comments admitting the timing is heuristic ("Give the inner viewer's
  `book.loaded.navigation.then(...)` a beat"). If/when un-skipped, prefer
  `expect.poll(...)` against `epubCacheHas(app.page, book.id)` to remove the
  arbitrary 500ms.  **Practice violation**.
- **L33-67** — Renderer-side diagnostic surface (`window.__readerCache.epub`)
  is read via `page.evaluate`. The pattern is sensible (contextBridge is frozen),
  but if testers find a finding here, the fix is on the production code, not
  the diagnostic surface. Make sure findings don't misattribute.
- **No CFI assertion.** A real "warm-restore" should arguably also assert the
  *position* in the book was preserved (CFI in `currentEpubLocation`), not just
  that the cache was hit. The cache contract test and the location-restore test
  are different things. **Parity gap** vs. `pdf-persistence.spec.ts`'s
  page-index assertion.
- **No ErrorBoundary assertion on cold open** — only on the warm reopen path
  (L114-117). Asymmetric coverage; record in `practices-audit.md`.

### 2.3 `e2e/azw3-real-import-routing.spec.ts` (warm-restore-relevant subset)

- **Not strictly a warm-restore spec.** Asserts import-routing (kind=azw3 not
  mobi). The "warm" angle is: after a reopen, does the kind persist? The test
  doesn't reopen the app — it only opens the book in-session. **Parity gap**:
  no AZW3 close+reopen test exists for kind persistence.
- **L23** — `test.setTimeout(60000)` — masks slow IPC; if the slowness is the
  bug, the longer timeout hides it. Confirm whether the AZW3 import path is
  actually slow on cold start. **Possible bug**, possible **practice violation**
  depending on what the slowness reveals.
- **L36-41** — Asserts `src=blob:` and `srcdoc===null` to distinguish Azw3View
  from MobiView. This is good behavior-over-implementation discrimination
  (would catch the bug it's named for). Defend this pattern.
- **No assertion that AZW3 unit-level parse logic exists.** MOBI has
  `formats-mobi.test.ts`; AZW3 has no equivalent. **Parity gap** —
  unit-coverage asymmetry across the format pair.

### 2.4 `e2e/mobi.spec.ts` (warm-restore-relevant subset)

- **L15-26** — `test.beforeAll(launchApp)` + per-test `deleteAllBooks` — shared
  Electron instance across tests is fragile if any test crashes the app.
  Compare to other specs that use `beforeEach(launchApp)`. **Practice
  violation**, low severity.
- **L29-34** — `importBook(...)` helper *hardcodes* `kind: 'mobi'`, bypassing
  the dispatcher (see `e2e/helpers/electron-app.ts:89-126`, particularly L114).
  This is the exact bug class `azw3-real-import-routing.spec.ts` was written
  to catch. **Parity gap**: MOBI should have a `mobi-real-import-routing` spec
  using `importBookViaOpenFile`.
- **L36-39** — `expect(...).toHaveCount(await ...count())` is a tautology
  (asserting a count equals its own current value). **Practice violation** —
  this assertion can never fail.
- **L40** — `expect(bookPage.locator('body')).not.toBeEmpty()` is a very weak
  rendering assertion — body has overlays/chrome that may never be empty.
  Replace with a content-specific locator (e.g. the chapter iframe / first
  paragraph). **Practice violation**.
- **L42-48** — "non-existent book id does not crash" — `waitForTimeout(1500)`
  is unbounded; if the crash is async it could happen after the wait.
  **Practice violation** (timing); also asserts `body` visibility which is
  again trivially true.
- **No reopen-restore test.** No close+reopen, no location preservation, no
  cache layer (MOBI has none) — but the format ought to remember at least the
  chapter index. **Parity gap** vs. PDF.

### 2.5 `src/renderer/src/stores/pdfStore.test.ts`

- **No restore-related coverage.** Despite the file being on the pilot scope
  list (paired with `pdf-warm-restore.spec.ts`), it covers page math, dual-page,
  thumbnails, books list, paragraph state. There is **no** test for restoring
  `pageNumber` from a persisted location, no test for `BookNavigationState`
  transitions during a restore. **Parity gap** (state-restoration unit test).
- **L6-23** — `beforeEach` calls `setState({ ... })` with a hand-crafted slice
  rather than the store's actual reset method (or calling `reset()`). Drift
  risk: if a new field is added to `PdfState` it won't be reset by this
  fixture. Compare to `epubStore.test.ts` which uses `reset()`. **Practice
  violation**.
- **L107-112** — `resetParagraphState` assertion only checks 3 of the 5 fields
  the reducer touches. The unchecked fields (`isHighlighting`, `isRenderedPageState`)
  are part of the same reset contract. **Coverage gap / practice violation**.
- **No tests for the side-effect subscription at L201-208** (the scrollPageNumber
  → pageNumber sync). This is exactly the code that participates in a restore
  flow. **Parity gap**.

### 2.6 `src/renderer/src/stores/epubStore.test.ts`

- **L101-110** — `should preserve theme across reset` — the comment block
  inside the test admits the author wasn't sure whether theme reset; the
  test asserts the *current* behavior rather than the *desired* behavior.
  This is a characterization test masquerading as a contract test. Confirm
  intent vs. behavior. **Practice violation**.
- **L51-55, L57-61** — `as any` casts on mock renditions. Acceptable for a
  unit test, but be aware: production `setRendition` accepts a real `Rendition`
  with side effects (the subscription at `epubStore.ts:174-207`). The unit
  test never exercises those subscriptions — **parity gap** between unit and
  integration coverage of `setRendition`.
- **No test for `publishCurrentEpubParagraphs()`, `initEpubSubscriptions()`,
  or `cleanupEpubSubscriptions()`** despite all being exported and being the
  bulk of the file. **Parity gap**.
- **No restore test.** No assertion that `setCurrentEpubLocation` survives the
  store across a reset/init cycle the way a reopen would. **Parity gap**.

### 2.7 `src/main/ipc/__tests__/formats-mobi.test.ts`

- This file is parse-only (`stripHtmlTags`, `parseMobiMetadata`,
  `parseMobiChapters`). It does NOT exercise the `formats:getMobiData`,
  `saveBook`, or `getBook` IPC handlers (`src/main/ipc/formats.ts:705`,
  `src/main/ipc/books.ts`). **Parity gap** — no AZW3 equivalent file exists
  at all (`src/main/ipc/__tests__/` contains only this and `auth.test.ts`).
- **L13-150** — `buildMobiBuffer` is a 137-line in-test fixture builder that
  produces a synthetic MOBI buffer. Defensible (avoids checking a binary
  fixture into the test file directly), but also a strong signal that an
  equivalent shouldn't need to be written for AZW3, EPUB, PDF — those have
  real fixture files (`e2e/fixtures/*.{epub,pdf,azw3}`). **Practice
  observation**: no test reads `e2e/fixtures/test-book.mobi` from disk to
  exercise the real parser path; the in-memory synthetic buffer may diverge
  from real files.

---

## 3. TDD Architecture Guidance

### 3.1 Vitest patterns used here

- `describe('<unit-name>', () => { ... })` at file top; nested describes are rare.
- `it('should <do thing>', () => { ... })` — `it` (not `test`) is the convention
  in stores.
- `beforeEach` for state reset. Prefer calling the store's own `reset()` /
  `setState({...})` — both patterns appear; `reset()` is cleaner (see
  `epubStore.test.ts:7`) and protects against future field additions.
- `expect(...).toBe(...)` / `.toEqual(...)` / `.toBeNull()` — synchronous,
  no `await` ceremony for sync store assertions.
- Mock objects are inline (`{ display: () => {} } as any`). Library-deep
  mocks (`vi.mock(...)`) are rare in this slice; do not introduce one
  unless required by an explicit boundary.
- `globals: true` is enabled in `vitest.config.ts` — no need to import
  `describe / it / expect / vi`.
- `happy-dom` is the environment, NOT `jsdom`. Be aware: `window` exists,
  `localStorage` exists, but some browser APIs are stubs.
- Test setup file: `src/renderer/src/test-setup.ts` runs before each test.

### 3.2 Playwright patterns used here

- `test.describe(...)` is used for grouping but not always (single-test
  files often omit it). Either is acceptable.
- Per-file `beforeAll(launchApp)` + `afterAll(closeApp)` is one valid
  pattern (see `mobi.spec.ts`); per-test `launchApp` / `closeApp` in a
  try/finally is the other (see `pdf-persistence.spec.ts`). Per-test is
  more isolating; prefer it for new tests unless launch cost is dominant.
- All Electron interactions go through `e2e/helpers/electron-app.ts`. Do
  NOT call `electron.launch` from inside a spec.
- Assertions use `expect(locator).<matcher>(...)` (with `await`) and
  `expect.poll(...)` for derived/computed state. Avoid raw
  `page.waitForTimeout(...)` in assertions; it's used here for *setup*
  pacing but recognized as flaky.
- Reader-window pages are obtained from `openBook(...)` (returns the new
  BrowserWindow's `Page`), NOT from `launched.page`. Phase-3 (per-book
  window) has landed.
- Renderer-side diagnostic surfaces (`window.__readerCache.<fmt>`) are
  the right tool when contextBridge can't be intercepted. Use them, don't
  monkey-patch IPC.

### 3.3 Where a red test belongs

| Bug class | Layer | Example pattern |
|---|---|---|
| Reducer/state-machine math wrong | Vitest, `src/renderer/src/stores/<store>.test.ts` | `usePdfStore.setState({...}); call action; assert state` |
| IPC handler wrong (parser, persistence) | Vitest, `src/main/ipc/__tests__/<handler>.test.ts` | Build a buffer/file, call exported function, assert result |
| User-visible reader behavior (visible iframe, page restored) | Playwright, `apps/rishi-electron/e2e/<feature>.spec.ts` | `await importBook(...)`, `await openBook(...)`, `await expect(locator).<assertion>(...)` |
| Cache hit/miss diagnostic | Playwright, asserting against `window.__readerCache.<fmt>.stats()` | Cold + warm reopen, reset stats between, assert hits>0 |
| Cross-window lifecycle (Phase 3) | Playwright, multiple Pages from same context | `launched.app.context().pages()`, `openBook` returns the book-window Page |

### 3.4 File-naming conventions for new tests

- Vitest unit: same dir as production source, `<name>.test.ts` (e.g.
  `pdfStore.test.ts` next to `pdfStore.ts`).
- Vitest IPC: `src/main/ipc/__tests__/<handler>.test.ts`.
- Playwright e2e: `apps/rishi-electron/e2e/<format-or-feature>-<verb>.spec.ts`
  e.g. `pdf-warm-restore.spec.ts`, `azw3-real-import-routing.spec.ts`,
  `mobi-global-page-counter.spec.ts`. For new MOBI/AZW3 warm-restore work,
  follow this pattern (e.g. `mobi-warm-restore.spec.ts`).
- Fixtures: `apps/rishi-electron/e2e/fixtures/test-book.<ext>`.

### 3.5 Mocking philosophy (the boundaries)

**Don't mock.** Read from a real temp file/dir. Use real SQLite. Use real
fixtures. Per repo convention (also in the spec):

- SQLite is real. Tests should launch the actual Electron main process
  (Playwright) or use the real `better-sqlite3` in unit tests. **Do not**
  introduce a SQL mock.
- `fs` is real. `launchApp` creates `os.tmpdir()` userDataDir and tears it
  down in `closeApp`. New tests should follow this.
- IPC bridge is real (contextBridge). Use the renderer's `window.electron`
  surface via `page.evaluate`; don't intercept.

**Do mock** (selectively):

- Inert side-effect objects in unit reducer tests, e.g.
  `{ display: () => {} } as any` for an epubjs Rendition (the rendition's
  side effects belong in integration/e2e tests, not the reducer unit).
- Network calls in service tests (none of the pilot-scope files do this,
  so don't introduce it).

If a finding says "this test should mock X", check whether X is at one of
the real-only boundaries; if so, the finding is wrong.

---

## 4. Finding-File Rules

### 4.1 Template re-statement

Every finding file is a copy of `/Users/faridmatovu/projects/rishi-monorepo/.agent-review/FINDING-TEMPLATE.md`,
saved as `.agent-review/pilot/findings/NNN-<short-slug>.md` where `NNN` is
zero-padded inside the tester's assigned ID range (001-005, 006-010,
011-015, 016-020). The template (paraphrased — see file for the canonical
copy):

- YAML frontmatter: `id`, `spec`, `status: open`, `created: YYYY-MM-DD`,
  `reviewer1_agent_type: team-reviewer | feature-dev:code-reviewer`,
  `dispatches_used: 0` (testers set this to 1 after filing).
- `## Bug Summary` — one paragraph: what's wrong, where, expected vs actual.
- `## Reproduction` — exact test file + line numbers, failing assertion
  text, exact command to run.
- `## Tester Analysis` — why this is a production bug, not a test problem.
  Cite production code paths (file + line).
- Remaining sections (`Reviewer-1 Verdict`, `Tester Rebuttal`, etc.) are
  appended later by other agents. Testers MUST leave them as the headings
  the template provides — do not pre-fill.

### 4.2 Cap: 5 findings per spec maximum

Testers MAY file fewer. They MUST NOT file more than five per assigned
spec. If a tester is tempted to file a sixth, the right move is:

- Re-read the existing five and remove the weakest.
- Or, if it's not a production bug, file it under `parity-gaps.md` /
  `practices-audit.md` instead.

The cap exists to keep the dispatch budget bounded (worst case
4 specs × 5 findings × 8 dispatches/finding = 160 dispatches; the global
soft cap is 60). Testers padding to look productive will starve the budget.

### 4.3 What is NOT a finding

These DO NOT go in `findings/`:

- **Parity gap**: format A tests capability X, format B doesn't.
  Production code may be correct — the test suite is just uneven. →
  `parity-gaps.md`.
- **Practice violation**: a test mocks the database when it shouldn't,
  uses `setTimeout` in an assertion, asserts an implementation detail,
  is a tautology (e.g. `mobi.spec.ts:36-39`). Production code is fine. →
  `practices-audit.md`.
- **Test that documents an undesirable but intentional behavior**: this
  is a spec issue, not a bug. → `practices-audit.md` with a note.

A finding requires: a real production code path that produces incorrect
user-visible behavior, and a test (existing or newly-conceived) that
demonstrates it.

### 4.4 Reviewer-1 alternation (for testers writing findings)

Set `reviewer1_agent_type` in the frontmatter based on the finding's ID:

- ID ending in odd digit (001, 003, 005, 007, 009, ...) → `team-reviewer`
- ID ending in even digit (002, 004, 006, 008, 010, ...) → `feature-dev:code-reviewer`

This diversifies blind spots across the reviewer pool.

---

## 5. Test Commands

### 5.1 Prerequisites

Playwright e2e tests require a built main process. The test entry resolves
`../../out/main/index.js` (see `e2e/helpers/electron-app.ts:12`). If
`apps/rishi-electron/out/main/index.js` is missing, build first:

```bash
pnpm --filter rishi-electron build
```

(Currently present in this working tree — verified.) `package.json` does NOT
have a `pretest:e2e` hook; the build must be run manually. Vitest unit tests
do not require a build.

The repo pins pnpm to `10.22.0` for release CI; locally any recent pnpm works
for running tests, but if `pnpm install` was needed, use 10.22.0 to match
(see `project_pnpm_pin.md`).

### 5.2 Vitest — specific file

From the repo root:

```bash
pnpm --filter rishi-electron test src/renderer/src/stores/pdfStore.test.ts
pnpm --filter rishi-electron test src/renderer/src/stores/epubStore.test.ts
pnpm --filter rishi-electron test src/main/ipc/__tests__/formats-mobi.test.ts
```

For a single `it(...)` block, append `-t "<partial test name>"`:

```bash
pnpm --filter rishi-electron test src/renderer/src/stores/pdfStore.test.ts -t "should navigate to next page"
```

### 5.3 Vitest — full unit suite (sanity)

```bash
pnpm --filter rishi-electron test
```

### 5.4 Playwright — specific file

Run from `apps/rishi-electron` (the `playwright.config.ts` testDir is
`./e2e`, so the cwd matters):

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/pdf-warm-restore.spec.ts
pnpm test:e2e e2e/epub-warm-restore.spec.ts
pnpm test:e2e e2e/azw3-real-import-routing.spec.ts
pnpm test:e2e e2e/mobi.spec.ts
```

> Note: `pdf-warm-restore.spec.ts` and `epub-warm-restore.spec.ts` are
> currently `test.skip(...)` (see §1 surprises). Running them will report
> "skipped" — that's the current parity gap, not a bug finding.

### 5.5 Playwright — single test by name

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm test:e2e e2e/mobi.spec.ts -g "MOBI book opens and renders"
```

### 5.6 Reviewer-1 flake check (≥3 runs)

Per the workflow spec, Reviewer-1 must run a failing test ≥3 times to
rule out flake. Example:

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e <spec> -g "<test name>" || echo "run $i: FAIL"; done
```

For Vitest:

```bash
for i in 1 2 3; do pnpm --filter rishi-electron test <path> -t "<name>" || echo "run $i: FAIL"; done
```

### 5.7 Verification of test discovery

Before filing a finding citing a test, confirm the runner sees it:

```bash
# Vitest
pnpm --filter rishi-electron test --reporter=verbose <path> | head -40
# Playwright dry-run (no execution)
pnpm test:e2e --list <spec>
```

---

## Closing notes for testers

- The two designated warm-restore e2e specs are both `.skip`. Most
  warm-restore content in this pilot lives in **what's NOT tested**, not in
  what fails. Expect the majority of your output to land in
  `parity-gaps.md`, not `findings/`. That is correct.
- If you find a true bug (an active test that exposes incorrect production
  behavior), excellent — file it. But do not invent one to meet a quota.
  Zero findings from a tester is a valid outcome.
- The most likely sources of *real* bugs in this slice, if they exist:
  the cache diagnostic surface (`pdf-cache.ts`, `epub-cache.ts`) — does
  it actually report stats correctly? — and the import-routing dispatcher
  for non-AZW3 KF8 extensions (the bug pattern AZW3 just fixed could exist
  for `.prc` or other Kindle variants).
