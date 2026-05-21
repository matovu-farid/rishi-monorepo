# Test-Infra Audit — Tester B-T2 (EPUB e2e batch)

Scope: shared helpers and conventions touched by the 4 EPUB e2e specs.
File references are to `apps/rishi-electron/e2e/helpers/electron-app.ts`
and the spec files in `apps/rishi-electron/e2e/`.

## TI-T2-01 — `importBook(...)` shortcut bypasses real dispatcher across the batch

All 4 EPUB specs call `importBook(page, { fixturePath, kind: 'epub', title })`.
The helper accepts and presumably honors the explicit `kind`, which short-
circuits the production import-dispatcher (mime sniff / extension parse).
Captured as parity-gap PG-T2-01; the infra observation here is that the
helper *enables* the gap by making the bypass the path-of-least-resistance.

**Recommendation:** add a sibling helper (or option flag) that imports via
the real OS-dispatch path (`importBookViaOpenFile` from
`epub-cache-no-flash.spec.ts` plan §2.5). Surface the kind-bypass as a
named option so it is greppable: `importBookSkipDispatch(...)` or
`importBook(page, { ..., bypassDispatch: true })`.

## TI-T2-02 — No shared `waitForReaderIdle(page)` helper

Every EPUB spec rolls its own settle heuristic — `waitForTimeout(500)`,
poll-for-iframe, or inline rAF poller. There is no helper named anything
like `waitForReaderIdle(bookPage)` that the specs can share. Six
`waitForTimeout` calls catalogued in practices-audit PA-T2-01 all point at
this missing primitive.

**Recommendation:** extend `e2e/helpers/electron-app.ts` with
`waitForReaderIdle(page, opts?)` that polls a documented idle signal
(e.g. `__readerCache.epub.stats()` stable for N frames, or absence of any
visible loader text). Replace the time-based settles with calls to it.

## TI-T2-03 — No `getEpubLocation(page)` / `expectLocationChanged(page, before)` helpers

Driven by finding B017 and parity-gap PG-T2-02: every navigation
assertion has to roll its own location-read evaluate block, which is
why none of the four specs do it. Add helpers:
```
export async function getEpubLocation(page: Page): Promise<string | null>
export async function expectEpubLocationChanged(page: Page, before: string, opts?: { timeout?: number }): Promise<void>
```
Backed by the `__readerCache.epub` surface (verified to expose a stable
key at `src/renderer/src/services/reader-cache/epub-cache.ts:38`).

## TI-T2-04 — `bookPage` cleanup pattern is duplicated across describes

`epub-text-selection.spec.ts` L69–78 documents the BrowserWindow-close
sequence with a load-bearing comment about the Phase-3 hang. The same
sequence is needed (or will be needed) in `epub-reader.spec.ts` and any
future multi-test EPUB describe. Today only text-selection has the
explicit `bookPage?.close()`; `epub-reader.spec.ts` afterAll (L27–30)
does not close the book window first — it relies on `closeApp` to do it.
That may work today but contradicts the documented hang risk.

**Recommendation:** add a helper `closeBookWindow(bookPage)` that
encapsulates the close-and-swallow-error pattern with documentation,
and call it from every describe's `afterAll`/`afterEach` consistently.

## TI-T2-05 — No standard for surfacing window-evaluated diagnostic state

`__readerCache.epub` (cache stats, has), `__loaderEverSeen`,
`__loaderPollHandle` (in the skipped cache-no-flash spec) — three
different ad-hoc patterns for stashing diagnostic state on `window` from
either production or test code. There is no documented namespace, no
typings file, no central listing.

**Recommendation:** declare a `window.__rishiTest` namespace (typed via
a `globals.d.ts` under `e2e/`) and migrate diagnostic surfaces under it
incrementally. Document in `e2e/README.md` (which may need creating).

## TI-T2-06 — `pretest:e2e` build hook missing

Plan §4.1 notes the build is manual (`pnpm --filter rishi-electron build`)
because no `pretest:e2e` hook exists. This is a friction point: a
forgotten build means `e2e/helpers/electron-app.ts:12`'s
`../../out/main/index.js` resolve fails or — worse — uses a stale build.

**Recommendation:** add a `pretest:e2e` script in `package.json` that
runs the main-process build, OR have `launchApp()` detect a stale
`out/main/index.js` (mtime older than newest `src/main/**/*.ts`) and
fail-loud with a build-hint message.

## TI-T2-07 — No flake-budget / retry policy documented for EPUB e2e

Plan §4.5 shows a 3-run flake-check loop, but the playwright config
itself (not read here) presumably governs retries. The EPUB batch has
multiple time-based settles (PA-T2-01) that are prime flake sources.
There is no documented expectation of how many retries are acceptable
before a finding is opened.

**Recommendation:** document in `e2e/README.md` (or playwright config
comments) the flake policy: e.g. "any test that needs `retries > 0` in
CI must have a corresponding `practices-audit` entry explaining why."

---

**Summary:** 7 test-infra observations. Two (TI-T2-02, TI-T2-03) would
materially reduce future practices-audit and finding volume.
