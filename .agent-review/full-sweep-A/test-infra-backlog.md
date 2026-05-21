# Phase A — Test Infrastructure Backlog

Issues that span multiple test files and require infrastructure-level work (helper rewrites, fixture changes, framework configuration). Not findings, not Type A test-quality, not parity gaps. For separate follow-up planning.

Example seed entry (from pilot): mobi.spec.ts orphan `BrowserWindow` teardown timeout — spans openBook helper and afterAll lifecycle.

## Tester T1

- **Store-reset helper missing across renderer stores.** 4 of 5 store test
  files (`authStore.test.ts`, `chatStore.test.ts`, `navStore.test.ts`,
  `playerStore.test.ts`) hand-craft `setState({...})` slices in `beforeEach`
  to approximate "reset to initial state". Only `indexingStore` exposes
  `reset()`. This is a cross-file infra issue, not a per-file practice
  violation. Recommended fix: add a tiny shared helper
  `resetStore(store, initialState)` OR add `reset()` to each store and adopt
  it uniformly. Without this, every new store field is a silent
  cross-test-leak surface across the renderer.

## Tester T10 (reader-cache + wildcard)

- **Injectable clock for `ReaderCache`.** `cache.ts:92, 116` use `Date.now()` directly. Tests work around it with `await sleep(2)` busy-waits (`cache.test.ts:42-50, 74-90, 148-167, 178-203`). A `now: () => number` option on `ReaderCacheOptions` would let tests drive `lastAccess` deterministically, enable a tie-break test that `cache.test.ts` cannot currently write, and remove ~6 sleeps from the file. Design change; not for this sweep.
- **Module-init side-effect ergonomics for `window.__readerCache.<fmt>`.** Both `pdf-cache.ts` and `epub-cache.ts` mount their diagnostic surface at import time. Unit-testing this (per finding A092) requires `vi.resetModules()` plus manual `delete (window as any).__readerCache` between cases. A shared helper — `apps/rishi-electron/src/renderer/src/services/reader-cache/__test-helpers__/with-fresh-cache-globals.ts` — that takes a callback, resets modules, clears the window global, and re-imports the named module(s) — would standardize the pattern for the two new test files and any future format (mobi-cache, azw3-cache).
- **Cross-cutting `window.__*` diagnostic shape-pinning convention (wildcard).** See finding A099. If accepted, the convention benefits from a shared assertion helper that takes a module path and a shape spec and verifies "imported module mounts `window.<key>` with these methods of these arities." Generic enough to apply to future diagnostics outside reader-cache (indexer progress probe, connectivity probe, etc.). Without this helper, every new diagnostic surface re-derives the test setup and the e2e-fallback-mask trap from A099 keeps recurring.
