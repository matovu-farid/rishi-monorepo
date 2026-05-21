# Test Infra Notes — Tester B-T8

Scope: `auth.spec.ts`, `import.spec.ts`, `library.spec.ts`, plus the
helpers they share (`e2e/helpers/electron-app.ts`).

## Helper surface used by this slice

- `launchApp()` / `closeApp(app)` — Electron launch wrappers. All three
  specs use them; only `library.spec.ts` and `auth.spec.ts` share a
  single launched instance (`beforeAll`).
- `deleteAllBooks(page)` — serial loop over `getBooks` + `deleteBook`.
  Used by `library.spec.ts:24` and `import.spec.ts:25` in `beforeEach`.
  Correct shape (sequential per the in-line lint comment to avoid
  SQLite-connection races).
- `importBook(page, opts)` — bypasses the dispatch path; goes directly
  to the parser IPC + `saveBook`. Comment at helper L132-134 makes the
  bypass explicit. The three parser tests in `import.spec.ts` also
  call the parser IPCs directly, so the bypass is intentional for
  parser-contract specs; the missing piece is *per-format*
  `importBookViaOpenFile` specs (see finding B104).
- `importBookViaOpenFile(launched, fixturePath)` — exists, used by
  `azw3-real-import-routing.spec.ts`. Underused: PDF/EPUB/MOBI have no
  equivalent spec.
- `openBook(page, bookId)` — opens a book in a new BrowserWindow and
  returns the new Page. Not directly imported by this slice's three
  specs (they hand-roll the wait in `library.spec.ts:61-70`).
  `library.spec.ts:39-72` should be refactored to use `openBook` for
  consistency with the rest of the suite.

## Helper improvements that would simplify this slice

1. **`waitForLibraryReady(page)`** — encapsulate the
   `reload() + waitForTimeout(1500) + locator('[data-tour="book-grid"]').waitFor()`
   pattern used five times in `library.spec.ts`. Single call site,
   single source of truth for the landmark.
2. **`waitForWelcomeModal(page)` / `dismissWelcomeModal(page)`** —
   auth.spec uses the welcome modal three times with inconsistent
   selectors (`Sign In` vs `Sign in`) and inline copy strings.
   Centralizing the locators avoids the casing drift filed in B101.
3. **`expectBookWindowOpen(ctx, bookId, { timeout })`** — replaces the
   hand-rolled polling loop in `library.spec.ts:61-70` and aligns with
   `openBook`'s internal wait.
4. **`closeAllBookWindows(launched)`** — explicit teardown for any
   `/books/<id>` page in the shared context. Needed for any spec that
   reuses a launched app across tests where one test opens a book
   window (currently `library.spec.ts` leaks one; see B105).
5. **`uniqueAppDataPath(prefix)`** — wraps `getAppDataPath` +
   `${Date.now()}-${random}` so tests like
   `import.spec.ts:66-78` ("copyFile + exists round-trips") cannot
   collide on the hard-coded `'/import-roundtrip.pdf'` filename.

## Test isolation posture

| spec | launch scope | per-test cleanup | leak risk |
| --- | --- | --- | --- |
| auth.spec.ts | shared `beforeAll` | none (tests mutate localStorage in-place) | high — order-dependent |
| import.spec.ts | shared `beforeAll` | `deleteAllBooks` | low — books-only state |
| library.spec.ts | shared `beforeAll` | `deleteAllBooks` + hash reset | medium — book BrowserWindow from L39-72 leaks |

Recommendation: move auth and library to `beforeEach(launchApp)`;
import can stay shared with a unique-filename fix to L71.

## Build prerequisite

Per plan §4, every e2e run for this slice needs
`pnpm --filter rishi-electron build` first. The harness resolves
`../../out/main/index.js`. If a finding requires re-running after a
helper change in `src/main/**`, rebuild before re-running.

## Flake-check command (per pilot §5.6)

```
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
for i in 1 2 3; do pnpm test:e2e e2e/library.spec.ts || echo "run $i: FAIL"; done
```

Suspected flaky tests in this slice (in priority order):

1. `library.spec.ts` "imported book appears in library and opens
   reader" — hand-rolled poll on shared context, plus the only test
   that mutates the BrowserWindow set.
2. `library.spec.ts` "right-click context menu deletes a book" —
   delete confirmation modal handling is ambiguous (B103) and inherits
   any leaked window from the prior test.
3. `auth.spec.ts` "welcome modal reappears after clearing
   localStorage" — single 1500ms sleep after reload as the only
   stabilization for a React route re-mount.

## Fixture coverage

- `PDF_FIXTURE` — used by import, library.
- `EPUB_FIXTURE` — used by import (parser only), library (one row in
  the search-filter test).
- `MOBI_FIXTURE` — used by import (parser only).
- No AZW3 fixture used in this slice; that path is covered by
  `azw3-real-import-routing.spec.ts` (out of slice).

Gap: no large-file fixture (would unlock the `checkFileSize === 'error'`
coverage noted in parity-gaps).
