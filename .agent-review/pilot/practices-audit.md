# Pilot - Practices Audit

Best-practice violations in existing tests. Not bugs in production; tracked for follow-up.

## Type A Queue

Items to fix in Wave 9 (the pilot's sequential fix wave). Each is scoped to 1-2 test files,
needs no production code change, and addresses a real masking / brittleness risk.

### Q01 — mobi.spec.ts tautological assertions (cannot fail under any DOM state)
**Source:** Tester 4 / `apps/rishi-electron/e2e/mobi.spec.ts:36-39`
**Classification:** Type A
**Suggested fix:** Replace `await expect(bookPage.locator('a[href="/"]')).toHaveCount(await bookPage.locator('a[href="/"]').count())` (L36-38) — which asserts a count equals itself and is unfalsifiable — and the near-tautology `expect(bookPage.locator('body')).not.toBeEmpty()` (L39) with a positive content-discriminating assertion: `await expect(bookPage.locator('iframe').first()).toBeVisible({ timeout: 15000 })` plus an `iframe.src` regex check distinguishing Azw3View's `blob:` from MobiView's `srcDoc`, mirroring the existing pattern in `apps/rishi-electron/e2e/azw3-real-import-routing.spec.ts:36-41`. Scoped to one spec file; no production change.
**Effort:** trivial
**Status:** fixed (was: queued)
**Commit:** see HEAD commit `test(test-review-Q01): replace tautological assertions in mobi.spec.ts`
**Notes:** The Q01 suggestion's MobiView-vs-Azw3View framing is stale: per `books.$id.lazy.tsx:83`, both `kind: 'mobi'` and `kind: 'azw3'` mount Azw3View (MobiView is dead code, as Q02-doc bullet for AZW3 also notes). The fix therefore asserts the same positive shape as `azw3-real-import-routing.spec.ts:36-41` (iframe visible + `src` matches `/^blob:/` + `srcdoc` null) — which still positively discriminates "reader mounted" from "blank page / wrong route", and would also catch a hypothetical regression that revived MobiView for MOBI. Build was already current (`out/main/index.js` dated today, 2026-05-21); skipped rebuild. The target test (`MOBI book opens and renders`) passes on the modified spec. The sibling `non-existent book id does not crash` test's `afterAll` hook times out — this failure is pre-existing (confirmed on baseline with my change stashed) and is the substance of Q02 plus an apparently unrelated teardown flake; not introduced by Q01.
**Code Review:** APPROVE
**Findings:** none (in-scope). Worth-checking, already tracked as Type-B follow-up and not blocking: the new `iframe.first()` locator inherits the same positional-fragility concern the audit flags against `azw3-real-import-routing.spec.ts:35` (Tester-3 bullet) — a chat-panel iframe could shadow the reader iframe; resolution requires a production `data-testid`, so out of Q01 scope.

### Q02 — mobi.spec.ts brittle waitForTimeout calls (3000ms + 1500ms)
**Source:** Tester 4 / `apps/rishi-electron/e2e/mobi.spec.ts:35,42-48`
**Classification:** Type A
**Suggested fix:** Replace `bookPage.waitForTimeout(3000)` at L35 (Azw3View bytes→blob→iframe path) with `await expect(bookPage.locator('iframe').first()).toBeVisible({ timeout: 15000 })` — Playwright auto-wait returns as soon as the iframe mounts. Replace the bogus-id `waitForTimeout(1500)` at L42-48 with a positive assertion (e.g. assert "Book not found" UI is visible, or navigation back to library) rather than relying on `body` visibility, which is trivially true. Scoped to one spec file.
**Effort:** trivial
**Status:** partially-fixed
**Commit:** see HEAD commit `test(test-review-Q02): replace waitForTimeout with positive assertions in mobi.spec.ts`
**Notes:** L35 fix was already landed by Q01 (`expect(iframe).toBeVisible({ timeout: 15000 })` at mobi.spec.ts:40-41). The remaining Q02 work — replacing the bogus-id `waitForTimeout(1500)` + tautological body-visibility assertion — is applied here. Production behavior on a bogus id (per `books.$id.lazy.tsx:30-41,60-62`): `useQuery`'s `queryFn` throws `new Error('Book not found')` when `getBook(id)` returns null, and the `isError` branch renders `<div>{error.message}</div>`. The new assertion `await expect(app.page.getByText('Book not found')).toBeVisible({ timeout: 15000 })` rides on that user-visible text, so the test now positively confirms the error path mounted instead of just "body exists". Build skipped — `out/main/index.js` is fresh (2026-05-21). Verification: running the bogus-id test in isolation (`--grep non-existent`) passes cleanly in 10.7s including afterAll teardown. Running the full spec, BOTH tests' assertions pass (the bogus-id test's new "Book not found" assertion succeeds), but the `afterAll` hook still times out at 60s — confirming Q01's pre-existing-teardown-flake finding. The teardown timeout is **not resolved** by this fix and is **out of Q02's scope**: root cause is test-isolation (test 1's `openBook(...)` spawns a separate `BrowserWindow` that is never closed before `afterAll`, so `app.app.close()` hangs on the orphan window). Proper fix is structural — either per-test launchApp/closeApp (already flagged as Tester-4 Type-B bullet at line 112 above) or explicit book-window cleanup in afterEach. Both options are larger than a Q02 assertion-replacement.
**Code Review:** APPROVE
**Findings:** none (in-scope). Verified: diff is test-only (no production touched); `getByText('Book not found')` matches `books.$id.lazy.tsx:34,60-62` exactly (`throw new Error('Book not found')` rendered via `<div>{error.message}</div>` in the `isError` branch); old `waitForTimeout(1500)` + body-visibility lines removed (not supplemented); 15s timeout matches Q01's pattern and is generous for a synchronous error render. Teardown-timeout flake confirmed pre-existing — `afterAll` calling `closeApp(app)` and `openBook`'s orphan-window behavior are unchanged since file creation at 046ae37e, so not introduced by this commit. Worth-checking (not blocking, not Q02 scope): `getByText('Book not found')` is a substring match by default; if any future toast/menu copy contains that phrase a strict-mode caller could double-match — resolution would be a `data-testid` on the error div, same Type-B production-affordance pattern the audit already tracks.

### Q03 — AZW3 test.setTimeout(60000) override masks slow-IPC regressions
**Source:** Tester 3 / `apps/rishi-electron/e2e/azw3-real-import-routing.spec.ts:24`
**Classification:** Type A
**Suggested fix:** Remove the `test.setTimeout(60000)` line and let Playwright's default 30s per-test timeout enforce a tighter budget — the spec only does one import + one openBook and should fit well inside 30s. If a particular stage is genuinely slow on cold-start CI, wrap it with `await expect(...).toPass({ timeout })` so the slow stage is identified rather than absorbed into a global override. Single-line removal in one spec.
**Effort:** trivial
**Status:** fixed
**Commit:** see HEAD commit `test(test-review-Q03): remove test.setTimeout override in azw3 spec`
**Notes:** The `test.setTimeout(60000)` was redundant — `playwright.config.ts:5` already sets a global `timeout: 60000`, so the per-test override was a no-op duplicating the project default rather than a true 30s→60s extension. Removing it is therefore a pure noise-reduction (now relying solely on the project config); it does NOT tighten the effective budget to Playwright's documented 30s default, because this project's config overrides that default. To actually enforce a 30s budget, the project config would need to drop `timeout: 60000` (out of scope for a single-spec fix — that change ripples across every spec in the suite). Wall-clock post-fix: the spec still times out at 60s in this local sandbox — same pre-existing teardown-hang documented in Q01/Q02 entries (orphaned `BrowserWindow` from `openBook` blocks `closeApp` during the `finally` block). Baseline (with `setTimeout(60000)` present) reproduces the identical 60s timeout, confirming my change is behavior-neutral and the underlying hang is the same structural test-isolation issue Q01/Q02 already attributed to `openBook`'s window-leak pattern. Wrapping the slow step in `toPass({ timeout: 30000 })` was considered but rejected: the hang is in `closeApp` (cleanup), not in a pollable assertion, so `toPass` doesn't apply. Did NOT restore the override because (a) it was a no-op anyway, and (b) the audit's goal — make slow regressions visible rather than absorb them — is unaffected by removal.

### Q04 — pdfStore.test.ts resetParagraphState assertion is incomplete (3 of 5 fields)
**Source:** Tester 1 / `apps/rishi-electron/src/renderer/src/stores/pdfStore.test.ts:106-112`
**Classification:** Type A
**Suggested fix:** The reducer at `apps/rishi-electron/src/renderer/src/stores/pdfStore.ts:166-173` resets `{isDualPage, pageCount, highlightedParagraphIndex, isHighlighting, isRenderedPageState}`; the test only verifies the first three. Add two assertions for `isHighlighting === false` and `isRenderedPageState === false` (or whichever default the reducer sets) so a regression that fails to reset either field fails the test. Scoped to one test file; no production change.
**Effort:** trivial
**Status:** queued

### Q05 — epubStore.test.ts reset test silently omits bookOutline contract
**Source:** Tester 2 / `apps/rishi-electron/src/renderer/src/stores/epubStore.test.ts:63-76`
**Classification:** Type A
**Suggested fix:** `epubStore.ts:74-91` reset() does NOT clear `bookOutline` (clearing is delegated to a subscription side-effect at `epubStore.ts:218-230`). The unit test lists every other field but omits `bookOutline` entirely, so either contract — "reset is comprehensive" or "reset deliberately preserves bookOutline" — passes today. Add one assertion documenting the current contract: `setBookOutline(stubOutline); reset(); expect(useEpubStore.getState().bookOutline).toBe(stubOutline)` (or `.toBeNull()` if planner confirms reset SHOULD clear it). Pick the assertion that matches current implementation and add a one-line comment citing the subscription as the clearing mechanism. Scoped to one test file.
**Effort:** trivial
**Status:** queued

### Q06 — pdfStore.test.ts beforeEach uses hand-crafted setState slice (field drift)
**Source:** Tester 1 / `apps/rishi-electron/src/renderer/src/stores/pdfStore.test.ts:5-23`
**Classification:** Type A
**Suggested fix:** The hand-crafted reset enumerates 13 fields but `PdfState` has 19+ (missing: `pdfDocumentProxy`, `pageNumberToPageData`, `pdfsRendered`, `isTextGot`, `virtualizer`, `isRenderedPageState`, `isLookingForNextParagraph`). Any new field silently leaks across tests. Mirror the `epubStore.test.ts:7` pattern — call the store's own `reset()` if it exists, OR introduce a tiny `__resetPdfStore()` helper colocated in the test file that returns `useFromPdfStore.getInitialState()` (Zustand's built-in) and call `setState(getInitialState(), true)` to do a full replace. Prefer the Zustand-native `getInitialState` route — zero production change required.
**Effort:** small
**Status:** queued

---

## Type B (Document Only)

The rest of the audit. These remain documented for follow-up but are not in scope for Wave 9.

### Tester 1 (warm-restore slice — pdf-warm-restore.spec.ts + pdfStore.test.ts)

- **Brittle absolute waits in `pdf-warm-restore.spec.ts`** at L47 (`waitForTimeout(3000)`), L54 (`waitForTimeout(1000)`), L59 (`waitForTimeout(2000)`). Total 6s of hard sleeps in a single spec with no diagnostic anchor. If/when un-skipped, replace with `expect.poll(() => pdfCacheHas(bookPage, book.id)).toBeTruthy()` (mirroring the EPUB pattern in `epub-warm-restore.spec.ts:94`) and `expect(canvas).toBeVisible({ timeout })` — Playwright auto-wait obviates the manual sleep at L47.
  **Classification:** Type B
  **Why not fixing now:** Spec is `test.skip(...)` (pdf-warm-restore.spec.ts:33) pending Phase-3 rework; fixing waits before un-skipping is premature. Bundle with the un-skip work.

- **Implementation-detail locator `canvas.react-pdf__Page__canvas`** at `pdf-warm-restore.spec.ts:50,67`. Couples the test to `react-pdf`'s internal class name. EPUB's analogous assertion (`epub-warm-restore.spec.ts:87`) uses `iframe`, a stable contract. Prefer a `data-testid` on the wrapper PdfPage component, or assert a higher-level signal (e.g. `expect.poll(() => bookPage.evaluate(() => document.querySelectorAll('canvas').length)).toBeGreaterThan(0)`).
  **Classification:** Type B
  **Why not fixing now:** Spec is skipped, and the cleanest fix requires adding a `data-testid` in production source (`PdfPage` wrapper) — couples production change to a skipped-test refactor.

- **Assertion on wrong window post-Phase-3.** `pdf-warm-restore.spec.ts:50,67` locate the canvas on `app.page`, but Phase-3 puts the reader in a separate `BrowserWindow` whose Page is the return value of `openBook(...)`. The skipped spec never assigns the return value (L46, L56 — `await openBook(...)` discards the returned Page). When un-skipped, this is the first fix: `const bookPage = await openBook(app.page, book.id)`. Compare to the correct pattern at `pdf-persistence.spec.ts:21` and `:47`.
  **Classification:** Type B
  **Why not fixing now:** Spec is skipped; this fix is part of the un-skip migration, not an isolated practice fix.

- **No mutation/cleanup test for the side-effect subscription `pdfStore.ts:201-208`.** The subscription is module-level (registered once at import time), which makes it hard to test in isolation but doesn't excuse the lack of coverage — the gating logic (`bookNavigationState !== Navigating` → mirror scrollPageNumber to pageNumber) is exactly the kind of subtle predicate that warm-restore depends on (don't clobber the restored page with an in-flight scroll event during the initial mount).
  **Classification:** Type B
  **Why not fixing now:** Testing a module-level subscription cleanly requires a production refactor (extract the subscription factory so it can be re-registered against a fresh store in tests). That's not a 1-2 file change.

- **`pdf-warm-restore.spec.ts:62-64` `toHaveCount(0)` against a string locator** (`text=Something went wrong`). This is fine in isolation, but stronger would be asserting on the ErrorBoundary's actual fallback container by `data-testid` or role, so a *different* error string in the boundary still fails the test. Current assertion can be bypassed by renaming the user-visible string while leaving the boundary broken.
  **Classification:** Type B
  **Why not fixing now:** Borderline impact (assertion still works today); cleanest fix needs an ErrorBoundary `data-testid` in production source.

### Tester 2 (epub-warm-restore.spec.ts + epubStore.test.ts)

- **`epub-warm-restore.spec.ts` asserts on the wrong Page object post-Phase-3.** Lines 84, 86, 102, 104, 114-117 use `app.page.locator(...)` to look for the EPUB `iframe`, but Phase-3 (per the skip comment at L69-74) puts the reader in a separate BrowserWindow whose Page is the return value of `openBook(...)`. The current spec discards that return value (`await openBook(app.page, book.id)` at L84 and L102). When un-skipped, the first fix is to capture `const bookPage = await openBook(app.page, book.id)` and assert against `bookPage`. Same anti-pattern as PDF-side (cross-reference Tester 1's bullet). Compare to the correct pattern at `e2e/pdf-persistence.spec.ts:21`.
  **Classification:** Type B
  **Why not fixing now:** Spec is skipped; this is part of the un-skip migration.

- **Brittle absolute waits in `epub-warm-restore.spec.ts`.** L92 (`waitForTimeout(500)`), L99 (`waitForTimeout(500)`), L107 (`waitForTimeout(500)`). The inline comments admit the timings are heuristic ("Give the inner viewer's `book.loaded.navigation.then(...)` a beat"). Replace with `await expect.poll(() => epubCacheHas(app.page, book.id)).toBe(true)` for the cache-population gate at L92, and rely on Playwright's auto-wait on `expect(iframe).toBeVisible({ timeout })` for the visibility gates — the post-visibility 500ms at L107 is the worst offender because the subsequent `epubCacheStats` read is racing the inner viewer's microtask that increments hits.
  **Classification:** Type B
  **Why not fixing now:** Spec is skipped; fixing waits before un-skipping is premature.

- **`epubStore.test.ts:101-110` is a characterization test, not a contract test.** The test name (`should preserve theme across reset (theme is not reset)`) and the body's inline comments ("Actually, looking at the store, reset() only resets specific fields and theme is NOT in the reset set, so let's verify") betray that the author was documenting current behavior rather than asserting intended behavior. The implementation at `epubStore.ts:74-91` indeed omits `theme` from the reset payload, but there is no spec document declaring whether that is intentional. If theme is meant to be a session-persistent UI preference, this test should reference that requirement (or live next to a `persist` middleware test, not next to `reset()`). If it's an oversight, the test is locking in a bug. Resolve with the planner before keeping.
  **Classification:** Type B
  **Why not fixing now:** Requires a planner/product decision on whether theme-preservation is intentional. Not a mechanical fix.

- **`epubStore.test.ts:51-55, 57-61, 67, 124, 127` `as any` casts on mock renditions.** Acceptable for reducer-only unit tests, but the production `setRendition` is wired to a subscription at `epubStore.ts:174-207` that calls `getCurrentViewParagraphs(rendition)`, `getNextViewParagraphs(rendition)`, etc. on the rendition. None of those code paths are exercised because the mock has no real `Rendition` shape. If a refactor splits `setRendition` from the subscription seeding logic, these tests will continue to pass while the integration silently breaks. Either keep the unit test honest by asserting on `setRendition`'s direct effect only, or add an integration test (renderer-level Vitest with happy-dom, or playwright) that exercises the subscription.
  **Classification:** Type B
  **Why not fixing now:** Proper fix is "add an integration test exercising the subscription" — a new test file, not a fix to existing ones. Belongs in the parity-gaps follow-up, not Wave 9.

- **`epub-warm-restore.spec.ts` has no cold-side ErrorBoundary assertion.** L113-117 asserts "no ErrorBoundary fallback after reopen" but never checks the same on the cold first open at L84-89. Asymmetric coverage — a regression that crashes on cold open and recovers on warm reopen would pass this test. Mirror the assertion at both gates.
  **Classification:** Type B
  **Why not fixing now:** Spec is skipped; fold into the un-skip pass.

### Tester 4 (MOBI slice — mobi.spec.ts + formats-mobi.test.ts)

- **`mobi.spec.ts:29-33` uses `importBook` helper that bypasses dispatch.** The helper at `e2e/helpers/electron-app.ts:89-126`, especially L113-122, hardcodes `kind: 'mobi'` into the `saveBook` payload, completely skipping `dispatchFormatExtraction` (`src/renderer/src/services/book-import/dispatch.ts:43-56`). This is the exact bug class that `azw3-real-import-routing.spec.ts` was written to catch. For MOBI today, the production dispatch path produces the same `kind: 'mobi'`, so this is a test-quality issue (the test cannot detect a hypothetical regression in `formatFor('mobi')` or `dispatchFormatExtraction`), not a production bug. Type B: file a follow-up `mobi-real-import-routing.spec.ts` using `importBookViaOpenFile` (helpers L138-178). Cross-reference parity-gaps.md entry.
  **Classification:** Type B
  **Why not fixing now:** Substantive fix is "write a new spec file" (mobi-real-import-routing.spec.ts), not a fix to existing tests. Logged in parity-gaps and PA-011-IMPORTBOOK below as the helper-level concern.

- **`mobi.spec.ts:15-26` uses `beforeAll(launchApp)` + per-test `deleteAllBooks` (shared Electron instance).** If the first test mutates global app state (e.g., crashes the renderer, leaves a dialog open, leaves IPC handlers in a weird state), the second test inherits the broken state. Compare to `pdf-persistence.spec.ts` which does per-test `launchApp`/`closeApp` in a `try/finally`. Per the plan's TDD guidance ("per-test launchApp is more isolating; prefer it for new tests unless launch cost is dominant"), this is a candidate for switching unless launch cost has been measured and proven to dominate.
  **Classification:** Type B
  **Why not fixing now:** Borderline impact and contested — plan explicitly says "unless launch cost has been measured". No measurement available; switching may double the spec's wall-clock cost. Document for now.

- **`formats-mobi.test.ts:13-150` `buildMobiBuffer` is a 137-line in-test synthetic fixture, no real-file path.** The real fixture `e2e/fixtures/test-book.mobi` is available and is loaded by `src/renderer/src/components/azw3/parser.mobi.test.ts:11`. The IPC test never reads it, so the parser is tested only against a minimal hand-built buffer. Practice violation: prefer reading the real fixture for at least the smoke-test cases (`parseMobiMetadata` extracting any non-empty title, `parseMobiChapters` returning length > 0), with synthetic buffers reserved for edge cases (zero chapters, malformed EXTH, oversized buffer).
  **Classification:** Type B
  **Why not fixing now:** The synthetic buffer is defensible (allows pinning edge cases that a real fixture can't cover); adding real-file smoke tests is additive work better captured as a parity-gap follow-up than a Wave-9 in-place fix.

### Tester 3 (azw3-real-import-routing.spec.ts)

- **`iframe.first()` is positional and fragile.** At spec L35, `bookPage.locator('iframe').first()` will return whichever `<iframe>` mounts first. If a chat panel, OAuth popup, or onboarding tutorial ever ships an iframe into the reader window (some already do — see `components/chat/ChatPanel` imported by `Azw3View.tsx:13`), this locator can grab the wrong frame and the rest of the assertions become meaningless. Prefer a scoped locator (`bookPage.getByTestId('azw3-chapter-iframe')` or `bookPage.locator('[data-format="azw3"] iframe')`); add the testid in production source if missing. Same concern applies to any spec that does `iframe.first()` without a parent scope.
  **Classification:** Type B
  **Why not fixing now:** Cleanest fix needs a `data-testid` added to production source (Azw3View / its iframe wrapper) — couples a production change to the test fix.

- **`expect(srcdoc).toBeNull()` is dead-coverage and the comment that justifies it is stale.** At spec L38, 41, the inline comment says the assertion distinguishes Azw3View from MobiView. Per `apps/rishi-electron/src/renderer/src/routes/books.$id.lazy.tsx:10-12,83`, MobiView is dead code; both `kind: 'mobi'` and `kind: 'azw3'` dispatch to Azw3View. The assertion can no longer fail under any realistic regression path — even a future AZW3-imported-as-MOBI bug would still mount Azw3View, still produce `src=blob:`, and still leave `srcdoc === null`. Update the comment to reflect that the `getBookKind` assertion at L29 is the load-bearing check, OR replace the iframe-shape assertions with a content-level check that actually rides on whether the AZW3 parser ran (e.g. iframe text content contains a chapter-1 phrase from the fixture). Also tracked as PG-016-A in `parity-gaps.md`.
  **Classification:** Type B
  **Why not fixing now:** "Drop or rewrite the assertion" is contested between the two suggested resolutions; the proper replacement (content-level assertion that rides on the parser) requires knowing a stable phrase from `e2e/fixtures/test-book.azw3` chapter 1. Borderline impact (the surrounding `getBookKind` assertion already pins the contract).

- **Helper `importBookViaOpenFile` short-circuits the renderer-side dispatcher when paired with `importBook`.** Not a violation of *this* spec, but called out because the spec's own preamble (L17-22) documents the masking risk explicitly. The persistent presence of `importBook` (`e2e/helpers/electron-app.ts:89-126`) with its hardcoded `kind: input.kind` (L114) is a structural test-quality issue, filed as finding 011. Practices-audit angle: every PR adding a new e2e spec for an import flow should default to `importBookViaOpenFile`; `importBook` should be reserved for tests that explicitly need to bypass dispatch (e.g. seeding a corrupt-kind row to test recovery). Consider renaming the helper to `seedBookBypassingDispatch` to make the bypass intent explicit at call sites — every spec that opts in is acknowledging it does not exercise the real pipeline.
  **Classification:** Type B
  **Why not fixing now:** See PA-011-IMPORTBOOK below — covers the same structural concern, also Type B for the same reason.

### PA-011-IMPORTBOOK (carried over from rejected finding 011)

- **`importBook` helper at `apps/rishi-electron/e2e/helpers/electron-app.ts:89-126` hardcodes caller-supplied `kind` (L114) and discards parser-returned `data.kind` (read at L107).** This is a parallel implementation of `runImport` in `src/renderer/src/services/book-import/importer.ts:118-158` (which uses `bookData.kind` at L153). Every legacy spec that calls `importBook` will report the "right" kind even if the production dispatcher were misrouting the file. Reviewer-1 correctly classified this as test-infrastructure (no current user-visible bug), and the tester accepted that rejection. The substance — that the helper's contract drifts from production's — remains a legitimate test-quality concern. Remediation options: (1) change `importBook` to derive parse IPC from extension and pass `data.kind` through to `saveBook` (mirror runImport), or (2) rename to `seedBookBypassingDispatch` and migrate all import-flow specs to `importBookViaOpenFile`.
  **Classification:** Type B
  **Why not fixing now:** This is a multi-file restructuring: either changes the helper's signature (rippling through every spec that calls it — currently mobi.spec.ts, pdf-persistence.spec.ts, epub-* specs, and more) OR introduces a parallel helper plus migrates call sites. Either path is its own project, not a Wave-9 in-place test fix. The dispatch-bypass risk is currently insured against at the AZW3 boundary by `azw3-real-import-routing.spec.ts` using `importBookViaOpenFile`; the per-format parity gaps are tracked in `parity-gaps.md` and are the appropriate follow-up.
