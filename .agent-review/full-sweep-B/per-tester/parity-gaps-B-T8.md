# Parity Gaps — Tester B-T8

Scope: `auth.spec.ts`, `import.spec.ts`, `library.spec.ts`.

Format: `<spec> :: <gap> :: <suggested coverage>`.

## auth.spec.ts

- `auth.spec.ts` :: No coverage of the desktop OAuth deep-link handoff
  (Redis polling per `feedback_redis_polling_auth.md` +
  `project_electron_deeplink_auth.md`). The three current tests assert
  only that the Sign In link is visible and that the welcome modal
  toggles on localStorage clear. A complete regression of the polling
  handshake (token never arrives, polling abandoned, callback URL
  malformed, deep link not registered as default protocol handler)
  would pass every test in this file. :: Add `auth-deeplink.spec.ts`
  driving `app.evaluate(({app}, url) => app.emit('open-url', {...}, url))`
  with a mock callback URL and asserting the renderer transitions to a
  signed-in surface (or surfaces a recoverable error).

- `auth.spec.ts` :: No assertion that auth state survives an Electron
  reopen. The "Maybe later" persistence test (L33-45) reloads the
  renderer but does not relaunch the main process. The persistence
  contract that matters in production is "user closed the app and
  reopened it" — that path is uncovered. :: After dismissing the
  welcome modal, `closeApp(app)` + `launchApp()` + assert the modal is
  still absent.

- `auth.spec.ts` :: No coverage of sign-out. Sign In is tested as a
  visible affordance; sign-out (cookie/token clear, return to welcome
  modal) has no test. :: Add a test that signs in via a stubbed token,
  invokes sign-out, asserts the welcome modal reappears.

## import.spec.ts

- `import.spec.ts` :: No `*-real-import-routing.spec.ts` equivalents
  for PDF, EPUB, or MOBI. Only AZW3 has dispatch-vs-parser coverage
  (`azw3-real-import-routing.spec.ts`, post pilot 011). See finding
  B104. :: Add three new specs driving `importBookViaOpenFile` for
  each format and asserting the persisted `kind` via `getBookKind`.

- `import.spec.ts` :: Only PDF is round-tripped through `getBooks()`
  (L80-92). EPUB and MOBI imports are never persisted-and-recalled.
  If `saveBook` regresses on a non-PDF kind (e.g., binary cover
  serialization breaks for EPUB), this file passes. :: Replicate the
  L80-92 pattern for EPUB and MOBI.

- `import.spec.ts` :: No coverage of the import-error UX (corrupt
  file, unsupported extension, mid-import IPC throw). The success
  path is exercised but the failure-presentation contract is not. ::
  Add a test that copies a known-corrupt fixture, drives import, and
  asserts a user-visible error toast/banner appears.

- `import.spec.ts` :: No `checkFileSize`-returns-`'error'` coverage.
  The warn/error gate (per `2026-04-23-large-file-handling.md`) is
  load-bearing for the large-file confirmation UI; only the `'ok'`
  case (collapsed with `'warn'`) is exercised. :: Add a fixture
  larger than the hard limit (or stub the size-check threshold) and
  assert `'error'`.

## library.spec.ts

- `library.spec.ts` :: List ordering is asserted nowhere. The
  "search filters book list by title" test imports two books (L74-99)
  but never checks display order against insertion / title / recency.
  A regression that randomizes or reverses the order passes. ::
  Snapshot the order of `[data-tour="book-grid"] > div` children
  textContent against the import sequence.

- `library.spec.ts` :: No assertion that delete cleans up the on-disk
  copy under `getAppDataPath` (where `importBook` writes at L93-94).
  The SQLite row is checked indirectly via title disappearance; the
  file copy is not. A leak would silently accumulate. :: After delete,
  assert `electron.exists(<dest>)` returns false.

- `library.spec.ts` :: No coverage of the empty-library state after a
  delete brings the count to zero (empty-state copy, drag-and-drop
  prompt). :: After the L101-118 delete, assert the empty-library
  affordance reappears.

- `library.spec.ts` :: No coverage of search-no-results. Filter to
  "Alpha" with no matching book is uncovered; a regression that
  collapses no-results to "everything visible" passes. :: In the
  search-filter test, add a third fill with a known-absent token and
  assert grid has zero rows and a "no results" affordance is visible.
