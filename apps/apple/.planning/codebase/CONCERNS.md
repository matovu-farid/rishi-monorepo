# Codebase Concerns

**Analysis Date:** 2026-06-09

**Target:** `apps/rishi-electron` (Electron + electron-vite desktop app).
**Lens:** Technical debt, fragility, security/privacy boundaries, performance hotspots,
and — critically — anything that **blocks direct code reuse on a native iOS port**.

> Reading guide for the iOS parity effort: each entry tagged **`[iOS-BLOCKER]`** is
> a hard barrier to lifting the code as-is. Entries tagged **`[iOS-PORTABLE]`**
> describe logic that is portable in principle but needs a native-shaped seam.

---

## Tech Debt

**Format extraction lives in two worlds, with regex-based parsers — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/formats.ts` (745 LOC), `src/renderer/src/components/azw3/parser.ts`,
  `src/renderer/src/modules/epubwrapper.ts` (1100 LOC), `src/renderer/src/components/epub/EpubView.tsx` (1501 LOC).
- Issue: EPUB OPF metadata is parsed in the main process with hand-rolled regex
  (`/<dc:title[^>]*>([^<]+)<\/dc:title>/i`, plus 6 fallback regex for cover detection in
  `formats.ts:48-95`) because `epubjs` requires DOM and won't run in Node. AZW3 is parsed in
  the renderer (`parser.ts`) via `foliate-js` for the same reason. Two parser surfaces,
  two pagination engines, two highlight engines — see `docs/REFACTOR_FORMATS_PLAN.md` for
  the in-flight DRY effort.
- Impact: Any new metadata field (subtitle, series, etc.) has to be added in N places.
  iOS port has to rebuild *all* of this against native parsers (PDFKit / a Swift EPUB
  parser) or compile WASM equivalents.
- Fix approach: Move all format metadata extraction behind a single per-format adapter
  interface, then implement Swift-native adapters on iOS.

**Renderer file `EpubView.tsx` is 1501 lines — `[iOS-PORTABLE]`**
- Files: `src/renderer/src/components/epub/EpubView.tsx`,
  `src/renderer/src/components/pdf/components/pdf.tsx` (1218 LOC),
  `src/renderer/src/components/azw3/Azw3View.tsx` (914 LOC),
  `src/renderer/src/machines/playerMachine.ts` (1049 LOC, 1503-line test).
- Issue: View components co-locate reader UI, highlight overlay management, TTS
  reconciliation, navigation history, menu wiring, gesture handling, and persistence
  side-effects. State machines for reader playback already exist
  (`actors/epubViewActor.ts`, `actors/pdfViewActor.ts`) but the view still owns large
  swathes of orchestration.
- Impact: Hard to port — UI logic is tangled with platform IPC. Many hook lints are
  suppressed because of the size (`react-hooks/exhaustive-deps`, `set-state-in-effect`).
- Fix approach: Continue extracting per-concern hooks into `src/renderer/src/hooks/reader/`
  (already started — `useBookSyncId`, `useReaderMenuSync`, `useCommonMenuHandlers` exist).

**Two competing window-focus tracking systems — `[iOS-PORTABLE]`**
- Files: `src/main/index.ts:299-340` (`lastMenuOwnerWcId`, `setMenuOwner`).
- Issue: `BrowserWindow.getFocusedWindow()` is unreliable under Playwright (E2E races) and
  Cmd-Tab, so a parallel `lastMenuOwnerWcId` tracker is maintained. Every menu/focus path
  has to remember which one to consult.
- Impact: Easy to regress. Adding a new menu command requires updating both paths.
- Fix approach: Centralize through `WindowManager` (`src/main/windows/windowManager.ts`).
  Not portable to iOS at all — iOS app architecture has a single key window.

**Legacy auth shims still in preload — `[iOS-PORTABLE]`**
- Files: `src/preload/index.ts:79-83` (`clearAuth`, `getUserFromStore`, `saveUserToStore`),
  `src/main/ipc/auth.ts` (entire file is the legacy Clerk-shaped store).
- Issue: Old Clerk-era user JSON store coexists with the new Better Auth flow. Comment
  in preload acknowledges this: "Legacy auth shims — kept for backwards-compat with
  renderer code that hasn't been ported off the old Clerk-shaped helpers yet."
- Impact: Two sources of truth for "who is the user." Migration is incomplete.
- Fix approach: Audit renderer call sites for `getUserFromStore`; route through
  `window.api.auth.getSession()`; delete `src/main/ipc/auth.ts` and the shims.

**Drizzle ORM coexists with raw SQL — `[iOS-PORTABLE]`**
- Files: `src/main/database/queries.ts` (674 LOC, raw `prepare`),
  `src/main/database/drizzle.ts`, `src/main/ipc/sync.ts` (Drizzle),
  `src/main/sharing/libraryWrite.ts:48-66` (raw `prepare`).
- Issue: Some queries are Drizzle-typed; others are raw `db.prepare('INSERT INTO books...')`.
  Sharing's saveTransferredBook does a raw insert with a fixed-position arg list while
  the schema has 22 columns — easy to misalign on schema bumps.
- Impact: Schema migrations have to be replicated in two query styles. Type safety is
  partial.
- Fix approach: Pick Drizzle, port the rest. (Or keep raw SQL for hot reads and use
  Drizzle only for writes — pick one rule.)

**Renderer caches and stores are scattered — `[iOS-PORTABLE]`**
- Files: 25+ Zustand stores in `src/renderer/src/stores/`, plus XState machines in
  `src/renderer/src/machines/`, plus `react-query` queries, plus
  `src/renderer/src/services/reader-cache/`.
- Issue: No single "what is this app's current state?" surface. State lives in Zustand,
  XState, React Query, refs, and `localStorage` (`rishi:tour-completed`, `rishi:welcome-seen`).
- Impact: Debugging state issues requires reading multiple sources; iOS port has to
  redo all of this.
- Fix approach: Continue the XState consolidation (`sessionMachine` is 1383 LOC and
  growing). Document the ownership boundary per state slice.

**Unguided localStorage usage — `[iOS-PORTABLE]`**
- Files: `e2e/helpers/electron-app.ts:38-41` (sets onboarding flags),
  search renderer for `localStorage`.
- Issue: Persisted preferences mix between `localStorage` (web-style),
  `store:get/set` IPC (Electron store), and the SQLite `books` table. No central
  preference layer.
- Impact: iOS port has to map each preference to UserDefaults or Core Data carefully.

---

## Known Bugs

**Selection popover can be clipped against viewport edges — `[iOS-PORTABLE]`**
- Files: `src/renderer/src/components/highlights/SelectionPopover.tsx:69`,
  `src/renderer/src/components/highlights/HighlightActionPopover.tsx:53`.
- Symptom: When the user makes a text selection near the right or bottom of the window,
  the popover renders off-screen.
- Trigger: Highlight/notes interaction near a viewport edge.
- Marker: Source comments tag both as `TODO(Wave F): clamp x/y to viewport so the popover
  doesn't get clipped against the right/bottom edges.`

**Renderer crash recovery requires a parent BrowserWindow — `[iOS-BLOCKER]`**
- Files: `src/main/index.ts:175-296` (`handleRenderProcessGone`, attached on lib window only).
- Symptom: Book windows do not have a `render-process-gone` handler explicitly attached
  in `attachLibraryWindowSideEffects`. Only the library window gets the recovery dialog.
- Trigger: Renderer process crash in a reader window.
- Workaround: User has to manually quit/reopen the book.
- Note: The factory at `src/main/windows/createBrowserWindow.ts` does not set up the
  crash handler either. Ticketed via #164.

**`render-process-gone` reason `launch-failed` only quits in packaged builds — `[iOS-PORTABLE]`**
- Files: `src/main/index.ts:217-225`.
- Symptom: In dev, a launch-failed crash silently returns and leaves a black window.
- Trigger: Broken HMR bundle, missing native module.

**Cover extraction via 6-stack regex fallback chain — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/formats.ts:60-105`.
- Symptom: Books with non-standard OPF cover declarations get no cover.
- Trigger: Unusual EPUB packaging.
- Workaround: Cover is rendered as a single zero byte (see `libraryWrite.ts:54`,
  `cover, x'00'` for shared books).

**Two writers race on `serverUrl` in renderer server — `[iOS-PORTABLE]`**
- Files: `src/main/utils/rendererServer.ts:172-179` (`require-atomic-updates` disabled).
- Symptom: The early-return guard at function top protects against this, but the disabled
  lint rule masks future regressions.
- Trigger: Concurrent calls to `startRendererServer`.

**Book windows can lose unsaved CFI when force-closed — `[iOS-PORTABLE]`**
- Files: `src/main/windows/createBrowserWindow.ts:46-78`.
- Symptom: The renderer's debounced location save (≈ 400-700ms) can be in flight when
  the user closes a window; a 1500ms flush window is used as a best-effort guard.
- Workaround: `win.webContents.executeJavaScript(...flushPendingSaves)` is invoked on
  close. Timing tradeoff: SIGINT/SIGTERM in main bypass it on purpose.

**Onboarding-flag E2E hack — `[iOS-PORTABLE]`**
- Files: `e2e/helpers/electron-app.ts:38-46`.
- Symptom: Tests set `localStorage` flags then `page.reload()` to skip tour. A real user
  cannot opt out programmatically.
- Trigger: First-launch UX.

---

## Security Considerations

**Wide preload surface exposes raw filesystem ops — `[iOS-BLOCKER]` for design, **`[iOS-PORTABLE]`** for hardening**
- Files: `src/preload/index.ts:53-66` (`readFile`, `writeFile`, `mkdir`, `removeFile`,
  `readDir`, etc.), `src/main/ipc/fs.ts`.
- Risk: The preload surface exposes filesystem operations to the renderer. Path
  validation lives only in `assertSafePath` in `src/main/ipc/fs.ts:8-15`, which
  scopes paths to `app.getPath('userData')` — but `readFile`/`writeFile`/`exists`
  and friends in `fs.ts` DO **NOT** all call it (only some do). Spot check
  `fs:readFile`, `fs:writeFile`, `fs:copyFile`, `fs:exists` for missing guards.
- Current mitigation: `contextIsolation: true`, `sandbox: false`, allow-list for
  `shell:openExternal` (`src/main/ipc/util.ts:10`).
- Recommendation: Audit every `handle('fs:...')` for `assertSafePath`; on iOS this whole
  surface disappears (App Sandbox handles it) and book files have to be referenced via
  document picker bookmarks.

**Book windows disable webSecurity — `[iOS-PORTABLE]`**
- Files: `src/main/windows/createBrowserWindow.ts:30-37`.
- Risk: Book windows run with `webSecurity: false` because epubjs renders into
  `about:srcdoc` iframes that Chromium otherwise sandboxes too aggressively. CSP and
  same-origin checks are off for any HTML rendered inside the book window.
- Current mitigation: Only book windows; library/settings keep `webSecurity: true`.
  Content is DOMPurified before injection (`dompurify` is a dep).
- Recommendation: When porting to iOS WKWebView, set up a content-rule-list-equivalent.
  Reaudit highlight/TTS code injection paths.

**Magic-link session token persisted via Electron safeStorage — `[iOS-BLOCKER]`**
- Files: `src/main/auth/session-store.ts`.
- Risk: `safeStorage.encryptString` ties session encryption to the OS keychain
  (Keychain on macOS, DPAPI on Windows, libsecret on Linux). On Linux without libsecret,
  the token is written as **plaintext** — comment acknowledges this:
  "Linux without libsecret — fall back to plaintext."
- Current mitigation: `mode: 0o600` on the file.
- iOS replacement: Use iOS Keychain Services (`kSecAttrAccessibleAfterFirstUnlock`).

**E2E session-token backdoor in the auth service — `[iOS-PORTABLE]`**
- Files: `src/main/auth/auth-service.ts:34-44`.
- Risk: `process.env.RISHI_E2E_SESSION_TOKEN` is read at `hydrate()` and, if present,
  written into the session store. Worker-side gate is `ENABLE_TEST_AUTH`. A misconfigured
  prod env that leaks this var would auto-sign-in the desktop on launch.
- Current mitigation: Env-var-only; production binaries don't ship it.
- Recommendation: Add a build-time assertion that the env var has no effect in packaged
  builds (e.g. gate behind `!app.isPackaged`).

**Deep-link `rishi://` accepts only `sharing/join?t=` but parses any `rishi://` arg — `[iOS-PORTABLE]`**
- Files: `src/main/sharing/deepLink.ts:42-65`.
- Risk: Argv scanning `process.argv.find((a) => a.startsWith('rishi://'))` accepts any
  matching arg. Currently only one path is honored (`/sharing/join`), but the parser
  surface area is "any URL starting with `rishi://`". A future code path that handles
  additional sub-paths needs to keep the strict allow-list pattern in `parseJoinToken`.
- Current mitigation: Exact `host === 'sharing'` and `segments[0] === 'join'` checks.
  Comment notes the `startsWith('join')` footgun explicitly.
- iOS replacement: Use Universal Links + an explicit per-path handler dictionary; do
  not parse `URL.host` loosely.

**Sentry DSN hard-coded as fallback — `[iOS-PORTABLE]`**
- Files: `src/main/utils/sentry.ts:6-10`.
- Risk: DSN ships in the binary as a fallback. Anyone unzipping the .app/.exe can read it.
- Current mitigation: DSN is a public ingest endpoint; abuse risk is bandwidth.
- Recommendation: Standard practice; flag if iOS port needs to rotate to a separate DSN.

**`util:getDevBypassSecret` exposes server-side dev-bypass — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/util.ts:27-29`.
- Risk: Reads `process.env.DEV_BYPASS_SECRET` and hands it to the renderer. Documented
  as a dev tool (memory note `reference_dev_bypass.md`), but the env var has to NEVER
  leak into a packaged build.
- Recommendation: Gate read behind `!app.isPackaged`.

**No CSP on the renderer server — `[iOS-PORTABLE]`**
- Files: `src/main/utils/rendererServer.ts`.
- Risk: The HTTP server that ships renderer assets sets no Content-Security-Policy
  header. `webSecurity: true` on lib/settings windows gives a partial fallback.
- Recommendation: Add a CSP header at the server. iOS equivalent: WKWebView config.

**Cross-origin fetch to `api.fidexa.org` not pinned — `[iOS-PORTABLE]`**
- Files: `src/main/auth/auth-service.ts:5`, `src/main/sharing/config.ts:11`.
- Risk: No certificate pinning. Acceptable for a Better Auth flow but worth documenting
  ahead of an iOS port where pinning is the norm.

---

## Performance Bottlenecks

**EPUB cover extraction reads entire file into memory — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/formats.ts:30` (`fs.readFile(filePath)` then `JSZip.loadAsync`).
- Problem: Even a single-MB EPUB pays the cost of loading the whole archive. Very
  large EPUBs (>100 MB) push memory hard.
- Cause: JSZip needs the full buffer for the central directory. No streaming parse.
- Improvement: Use a streaming ZIP reader or read just the central directory + cover
  entry. iOS port should prefer streaming from the start (ZIPFoundation).

**PDF parsing via `pdf-parse` extracts full text in main process — `[iOS-BLOCKER]`**
- Files: `src/main/ipc/formats.ts:138-148`.
- Problem: `pdf-parse` synchronously parses the entire PDF when only metadata + cover
  are needed. On a 200 MB textbook this blocks the main process for seconds.
- Cause: Library API offers no metadata-only mode.
- Improvement: Switch to `pdfjs-dist` `getMetadata()` on the renderer side or use a
  streaming parser in main. iOS: use PDFKit's `PDFDocument`.

**Vector search uses HNSW with capacity doubling — `[iOS-BLOCKER]`**
- Files: `src/main/vectordb/index.ts:213-235`.
- Problem: `hnswlib-node` (native C++) holds the entire index in memory per book.
  `DEFAULT_MAX_ELEMENTS = 10_000` doubles on overflow → memory blows up for very long
  books or very large libraries with many open indices.
- Cause: HNSW is RAM-resident by design.
- Improvement: LRU-evict cold indices. iOS: re-implement with Core ML Vector Index or
  ship a Metal-friendly Rust crate via Swift FFI; `hnswlib-node` has no iOS binary.

**Embedding model loaded into the main process — `[iOS-BLOCKER]`**
- Files: `src/main/vectordb/embeddings.ts:39-66`.
- Problem: `@xenova/transformers` loads `Xenova/all-MiniLM-L6-v2` (quantized, 25-30 MB)
  via ONNX Runtime in the main process. First call downloads weights from HuggingFace,
  cached locally. CPU-bound; blocks the main process during inference.
- Cause: Embedding pipeline is in-process for IPC simplicity.
- Improvement: Move to a worker thread or utility process. iOS: ship the same model via
  Core ML or `onnxruntime-objc`.

**Local renderer HTTP server serves every asset request synchronously — `[iOS-PORTABLE]`**
- Files: `src/main/utils/rendererServer.ts:108-160`.
- Problem: Node HTTP serves the bundled renderer. Each request reads from disk and
  buffers into memory (`readFile`).
- Cause: Simplicity. PDFs and EPUBs are served via a separate `local-file://`
  protocol handler at `src/main/index.ts:148-156`.
- Improvement: Add a small in-memory LRU. iOS does not need the server.

**Filesystem scanner is fully recursive in main process — `[iOS-BLOCKER]`**
- Files: `src/main/ipc/scanner.ts`.
- Problem: Walks the user's filesystem (Documents/Downloads/Desktop + per-platform
  extras) looking for book files. Sequential `await` with `realpath` and `readdir`
  per directory.
- Cause: Avoids fd exhaustion under deep trees.
- iOS replacement: Files app document picker; no recursive scan permitted on iOS due
  to App Sandbox. **This entire feature must be replaced on iOS.**

**Highlights/bookmarks/conversations queried per-book without indexes — `[iOS-PORTABLE]`**
- Files: `src/main/database/migrations.ts` (no `CREATE INDEX` for `bookId` columns
  visible in the migrations head).
- Problem: Queries like `highlights.list(bookId)` scan the table.
- Cause: Schema didn't add indexes initially.
- Improvement: Verify indexes on `highlights.bookId`, `bookmarks.bookId`,
  `conversations.bookId`. Add migration.

**Sentry traces sampled at 10% in production — `[iOS-PORTABLE]`**
- Files: `src/main/utils/sentry.ts:26`.
- Problem: `tracesSampleRate: 0.1` is fine; ensure the same setting is mirrored in
  the renderer Sentry init for cost predictability.

---

## Fragile Areas

**`render-process-gone` recovery and crash-loop guard — `[iOS-PORTABLE]`**
- Files: `src/main/index.ts:158-296`.
- Why fragile: Many branches (dev vs prod, launch-failed vs general, with/without parent
  window, focused/unfocused dialogs). 60-second rolling window of crash timestamps in a
  `Map`. No tests cited.
- Safe modification: Add a unit test of `recordCrash` + `handleRenderProcessGone` with
  a fake `dialog`.

**Single-instance lock + open-file + deep-link interleaving — `[iOS-PORTABLE]`**
- Files: `src/main/index.ts:550-577` (`second-instance` handler).
- Why fragile: argv parsing on Windows/Linux must distinguish flags (`-foo`), file
  paths, and `rishi://` URLs. Current filter is `slice(1).filter(a => !a.startsWith('-'))`
  — a malformed `--user-data-dir=` past index 0 would be treated as a file path.
- Safe modification: Use a real argv parser.

**Atomic write helper is the **only** durable-write primitive — `[iOS-PORTABLE]`**
- Files: `src/main/utils/atomicWrite.ts`,
  `src/main/auth/session-store.ts`, `src/main/vectordb/index.ts:237-243`.
- Why fragile: Multiple writers ride on `atomicWriteFile`; a regression here corrupts
  the session token and the vector index simultaneously.
- Safe modification: Comprehensive tests already exist (`atomicWrite.test.ts`); keep them
  green on any change.

**E2E suite uses sequential launches with staged-shutdown teardown — `[iOS-PORTABLE]`**
- Files: `e2e/helpers/electron-app.ts:51-100`, `playwright.config.ts`.
- Why fragile: 60+ E2E spec files (`e2e/*.spec.ts`); each launches Electron and tears
  it down. Documented memory: "Electron Playwright closeApp must do staged shutdown."
  Retries are enabled (`retries: process.env.CI ? 2 : 1`) — they paper over real
  rotating flakes. Escape hatch is `RISHI_E2E_NO_RETRIES=1`.
- Why fragile (cont'd): `page.waitForTimeout(1500)` is a wall-clock wait. Onboarding
  dismissal relies on `localStorage.setItem(...)` then `page.reload()`.
- Safe modification: Don't reduce retries without first fixing the underlying file-handle
  / shared-memory leak.

**No flush handler attached on the library window (only on book windows) — `[iOS-PORTABLE]`**
- Files: `src/main/windows/createBrowserWindow.ts:46-78`.
- Why fragile: Comment says "library window has nothing to save" — true today, but
  adding any persistent UI state to the library window without also adding a flush
  hook silently loses it on quit.

**`hnswlib-node` ABI version drift — `[iOS-BLOCKER]`**
- Files: `scripts/ensure-native-abi.cjs`, `package.json` `postinstall`,
  `src/main/vectordb/index.ts:60-75`.
- Why fragile: Native modules (`better-sqlite3`, `hnswlib-node`, `sharp`) must be
  rebuilt when Electron changes ABI. Multiple scripts + a marker file
  (`.electron-rebuild-version`) coordinate this. Comment: "pnpm only re-runs install
  scripts when the lockfile changes" — branch switches can silently leave a stale `.node`.
- Safe modification: Treat any `ERR_DLOPEN_FAILED` at boot as "run `pnpm rebuild:node`."

**Sharp libvips vendor copy is patched in post-install — `[iOS-BLOCKER]`**
- Files: `scripts/ensure-sharp-vendor.cjs`.
- Why fragile: pnpm v10 only honors `onlyBuiltDependencies` at the workspace root,
  so sharp's libvips downloader is skipped. The script manually re-runs it.
- iOS implication: Sharp is Node-native; iOS port has to swap to Core Image.

---

## Scaling Limits

**Vector index in-memory cache — `[iOS-BLOCKER]`**
- Resource: `Map<string, IndexEntry>` in `src/main/vectordb/index.ts:32`.
- Current capacity: Indexes are loaded on first use and stay resident. No eviction.
- Limit: Library with many books × 384-dim × N chunks per book all live in process RAM.
- Scaling path: Add LRU eviction. iOS will need this from day one due to memory pressure.

**SQLite WAL with `busy_timeout = 5000` — `[iOS-PORTABLE]`**
- Resource: `src/main/database/index.ts:38-41`.
- Current capacity: Single writer; readers can lock for up to 5s.
- Limit: Heavy import or sync can saturate the writer queue.
- Scaling path: Already covered by the indexer's serial backpressure.

**No upper bound on `openBookTitles` map — `[iOS-PORTABLE]`**
- Resource: `src/main/index.ts:80` (`openBookTitles = new Map<number, string>()`).
- Current capacity: Unbounded.
- Limit: User opens hundreds of books in one session; the Window submenu becomes
  unmanageable.
- Scaling path: Cap the Window submenu list at N most-recent.

---

## Dependencies at Risk

**`@xenova/transformers` (embedding model) — `[iOS-BLOCKER]`**
- Risk: Node-native via ONNX Runtime. No iOS distribution; transformers.js is web-first
  but iOS WKWebView ONNX is limited.
- Impact: All RAG/search features break on iOS without a replacement.
- Migration plan: Ship `Xenova/all-MiniLM-L6-v2` via Core ML on iOS.

**`hnswlib-node` (vector index) — `[iOS-BLOCKER]`**
- Risk: Native C++ N-API addon. No iOS build target.
- Impact: Vector search unavailable on iOS without a replacement.
- Migration plan: Port to a Swift HNSW (e.g. `swift-hnsw`), or use Core ML similarity
  index, or compile `hnswlib` C++ via XCFramework.

**`better-sqlite3` — `[iOS-BLOCKER]`**
- Risk: Native sync SQLite bindings for Node. No iOS support.
- Impact: All DB access in main breaks.
- Migration plan: Use GRDB or SQLite.swift on iOS.

**`sharp` (image processing) — `[iOS-BLOCKER]`**
- Risk: Native libvips bindings. No iOS build. Already requires post-install fixup
  in pnpm workspaces.
- Impact: Cover normalisation breaks.
- Migration plan: Core Image / `UIImage`.

**`pdf-parse` (PDF text extraction in main) — `[iOS-PORTABLE]`**
- Risk: Unmaintained-ish (last release Apr 2018). Pulls in `pdfjs-dist` under the hood.
- Impact: Stale; can crash on malformed PDFs.
- Migration plan: Use `pdfjs-dist` directly; iOS port uses PDFKit.

**`epubjs` (renderer-side EPUB rendering) — `[iOS-BLOCKER]` for code reuse, **`[iOS-PORTABLE]`** for behavior**
- Risk: Library is in maintenance mode; last published 2024-Q1. Relies on iframes +
  DOMParser.
- Impact: Whole reader experience hinges on it.
- Migration plan: iOS port already needs a web-based reader inside WKWebView OR a
  native EPUB reader. `foliate-js` (already a dep) is a candidate.

**`foliate-js` (AZW3/MOBI parser) — `[iOS-PORTABLE]`**
- Risk: Pre-1.0 (`^1.0.1`), small maintainer team.
- Impact: AZW3/MOBI support depends on it.
- Migration plan: Same library can run inside WKWebView on iOS.

**`react-pdf` + `pdfjs-dist` — `[iOS-PORTABLE]`**
- Risk: `react-pdf` reaches into private paths (`react-pdf/dist/DocumentContext.js`,
  `react-pdf/dist/LinkService.js`); see `src/renderer/src/components/pdf/components/pdf.tsx:12-15`.
  Comment acknowledges this: "internal paths but stable."
- Impact: A `react-pdf` major bump can break the PDF reader silently.
- Migration plan: Document and pin the import path; tests must cover.

**`@openai/agents` (^0.3.9) — `[iOS-PORTABLE]`**
- Risk: Pre-1.0. API churn is likely.
- Impact: Chat/agent functionality.
- Migration plan: Track upstream; the parked TanStack AI experiment (memory note
  `reference_tanstack_ai_experiment.md`) was rejected as still-buggy.

**`electron-updater` — `[iOS-BLOCKER]`**
- Risk: Electron-specific.
- Impact: Auto-update.
- Migration plan: iOS uses App Store for updates; remove entirely on iOS port.

**`@sentry/electron` — `[iOS-BLOCKER]`**
- Risk: Electron-specific package.
- Migration plan: `@sentry/react-native` on iOS.

---

## Platform-Specific Assumptions That Won't Survive an iOS Port

### Process model — **`[iOS-BLOCKER]`** wholesale

- Files: `src/main/index.ts`, entire `src/main/`, entire `src/preload/`.
- Assumption: Two-tier (main + renderer) process model with synchronous IPC via
  `ipcMain.handle` / `ipcRenderer.invoke`. Renderer uses `window.electron.*` /
  `window.api.*`.
- iOS reality: WKWebView has `WKScriptMessageHandler` (one-way) and `evaluateJavaScript`
  (call into the page). No equivalent of `ipcMain.handle`.
- Plan: Replace `preload/ipc-contract.ts` with a Swift-side router. Keep the channel
  names in a shared `packages/shared` so both implementations agree.

### Native modules with NODE_MODULE_VERSION — **`[iOS-BLOCKER]`**

- Files: `package.json` `pnpm.onlyBuiltDependencies`,
  `scripts/ensure-native-abi.cjs`, `scripts/ensure-sharp-vendor.cjs`,
  `scripts/mark-native-abi.cjs`.
- Modules: `better-sqlite3`, `hnswlib-node`, `sharp`, `onnxruntime-node` (asarUnpacked
  in `electron-builder.yml`).
- Reality: None of these have iOS binaries. Each needs a native Swift replacement
  (GRDB, swift-hnsw, Core Image, Core ML or onnxruntime-objc).

### `app.getPath('userData')` — **`[iOS-PORTABLE]`**

- Files: `src/main/database/index.ts:35`, `src/main/vectordb/index.ts:165`,
  `src/main/ipc/fs.ts:9-14`, `src/main/auth/session-store.ts:7-9`,
  `src/main/sharing/libraryWrite.ts:20-22`.
- Assumption: A single canonical writable directory exists.
- iOS reality: Use `URL.applicationSupportDirectory` (replacing) + Library/Caches
  for cache files. Document picker bookmarks for user-imported books.

### `app.getPath('home' | 'documents' | 'downloads' | 'desktop')` — **`[iOS-BLOCKER]`**

- Files: `src/main/ipc/scanner.ts:18-32`.
- Assumption: User has a home directory and the app can walk it for books.
- iOS reality: App Sandbox forbids this entirely. Only the Files-app picker grants
  access.

### `safeStorage` — **`[iOS-BLOCKER]`**

- Files: `src/main/auth/session-store.ts`.
- Assumption: Electron `safeStorage` API.
- iOS replacement: Keychain Services. Direct port required.

### Custom protocols (`local-file://`, `rishi://`) — **`[iOS-PORTABLE]`** with rewrites

- Files: `src/main/index.ts:138-156` (`local-file://`), `src/main/sharing/deepLink.ts`.
- Assumption: `protocol.handle` + `app.setAsDefaultProtocolClient`.
- iOS reality: Universal Links + `WKURLSchemeHandler` are the rough equivalents.
  Behavior maps but every call site must change.

### macOS `open-file` event — **`[iOS-BLOCKER]`** entirely

- Files: `src/main/index.ts:52-55`.
- Assumption: macOS Finder routes file double-clicks via this event.
- iOS reality: `UIDocumentPickerViewController` or `application(_:open:options:)`.

### Windows/Linux `argv` file delivery + second-instance — **`[iOS-BLOCKER]`** entirely

- Files: `src/main/index.ts:550-577, 595-598`.
- iOS reality: Apps are single-instance; argv is unavailable.

### BrowserWindow, menu bar, accelerators — **`[iOS-BLOCKER]`** entirely

- Files: `src/main/windows/`, `src/main/menu/`, `src/main/index.ts:299-505`.
- Assumption: Desktop windowing, application menu with platform-specific keyboard
  accelerators (`ACCELERATORS` per `src/main/menu/accelerators.ts`).
- iOS reality: Scenes/Views; no menu bar (iPadOS has key commands).
- Plan: Strip these on iOS; expose equivalent commands through SwiftUI menus on iPadOS
  via `UIKeyCommand`.

### `webUtils.getPathForFile` — **`[iOS-PORTABLE]`** with replacement

- Files: `src/preload/index.ts:66`.
- Assumption: Electron's `webUtils` returns a path for a renderer-side `File`.
- iOS reality: Drag-and-drop / picker delivers an `NSURL` already.

### `react-pdf` private path imports — **`[iOS-PORTABLE]`** with rebuild

- Files: `src/renderer/src/components/pdf/components/pdf.tsx:12-15`.
- Assumption: Vite resolves `react-pdf/dist/DocumentContext.js` /
  `react-pdf/dist/LinkService.js`.
- iOS reality: If the iOS reader uses PDFKit, these go away. If it uses a web reader,
  the import path concern carries over.

### Renderer HTTP server — **`[iOS-BLOCKER]`** entirely

- Files: `src/main/utils/rendererServer.ts`.
- Assumption: A localhost HTTP server delivers `out/renderer/` to BrowserWindow at a
  stable port. Comment: "Service Workers, Fetch, and other web platform APIs that
  Chromium restricts on `file://`."
- iOS replacement: WKWebView's `loadFileURL(_:allowingReadAccessTo:)` with proper
  resource grants, or `WKURLSchemeHandler`.

### `electron-updater` autoupdate — **`[iOS-BLOCKER]`** entirely

- Files: `src/main/ipc/updater.ts`, `src/preload/index.ts:147-150`.
- iOS reality: App Store handles updates.

### `process.mas` Google-OAuth gate — **`[iOS-PORTABLE]`** with rename

- Files: `src/main/auth/auth-service.ts:92`, `src/preload/index.ts:237`.
- Assumption: Mac App Store builds set `process.mas`.
- iOS reality: iOS is always equivalent of MAS; the same restriction would apply
  (Sign-in with Apple required).

### Node-only APIs scattered across main — **`[iOS-BLOCKER]`** wholesale

- Files: Every file in `src/main/` imports from `node:fs`, `node:path`, `node:crypto`,
  `node:http`, `node:url`, `node:child_process` (in scripts).
- iOS reality: None of these exist. Each requires a Swift Foundation equivalent.

### Browser-only APIs called from main process via dynamic import — **`[iOS-PORTABLE]`**

- Files: `src/main/vectordb/embeddings.ts:49` (`await import('@xenova/transformers')`),
  `src/main/ipc/formats.ts:138` (`await import('pdf-parse')`).
- Issue: Dynamic imports keep startup fast but defer the iOS-BLOCKER discovery to
  first use.

---

## Missing Critical Features

**No background indexing on app quit — `[iOS-PORTABLE]`**
- Problem: Indexing happens in the renderer (`src/renderer/src/services/book-import/indexer.ts`).
  If the user closes a book window mid-index, work resumes from scratch next time.
- Blocks: Large-library users see "warming up" repeatedly.

**No multi-device sync conflict UI — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/sync.ts` exposes `applyBookConflict`, etc.
- Problem: Conflict resolution happens silently; users see no merge UI.

**No telemetry on cover-extraction failures — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/formats.ts:30-130`.
- Problem: 6 fallback chains; when all miss, the book lands with a black square. No
  Sentry breadcrumb captures which fallback fired.

---

## Test Coverage Gaps

**No tests for `render-process-gone` recovery — `[iOS-PORTABLE]`**
- What's not tested: `handleRenderProcessGone` in `src/main/index.ts:175-296`. No spec
  hits the dialog or the crash-loop guard.
- Risk: Production crash recovery silently regresses.
- Priority: High.

**No test for `local-file://` protocol path traversal — `[iOS-PORTABLE]`**
- What's not tested: `registerLocalFileProtocol` in `src/main/index.ts:138-156`. The
  protocol handler `decodeURIComponent`s and passes to `net.fetch(pathToFileURL(...))`
  without an allow-list. The renderer can request `local-file:///etc/passwd` in dev.
- Files: `src/main/index.ts:138-156`.
- Risk: HIGH — every book-window renderer (which runs with `webSecurity: false`) can
  read any file the user can read.
- Priority: **Critical.** Add an allow-list (e.g., must be inside `userData` or the
  library scan dirs).

**No tests for `fs:*` `assertSafePath` coverage — `[iOS-PORTABLE]`**
- What's not tested: All `fs:*` handlers in `src/main/ipc/fs.ts`. Only some call
  `assertSafePath`. No spec verifies every handler enforces the boundary.
- Risk: Renderer-to-arbitrary-filesystem escape.
- Priority: High.

**No tests for `parseJoinToken` edge cases under second-instance argv — `[iOS-PORTABLE]`**
- What's not tested: `dispatchSecondInstanceArgv` for malformed URLs interleaved with
  legitimate flags.
- Priority: Medium.

**No test that `RISHI_E2E_SESSION_TOKEN` is ignored in packaged builds — `[iOS-PORTABLE]`**
- What's not tested: `src/main/auth/auth-service.ts:34-44`.
- Risk: Test backdoor reaches production.
- Priority: High.

**No coverage of large-file size enforcement in `fs:checkFileSize` — `[iOS-PORTABLE]`**
- Files: `src/main/ipc/fs.ts:24-31`.
- Risk: Limits silently drift if `SIZE_LIMITS` is edited.
- Priority: Low.

**Window-focus + menu install race conditions are e2e-only — `[iOS-PORTABLE]`**
- Files: `src/main/index.ts:299-505`.
- Risk: Logic is reactive to OS focus events that Playwright doesn't always deliver.
  Unit-test surface is small.
- Priority: Medium.

---

## iOS Parity Roadmap — Quick-Reference

| Concern | iOS Status | Native Replacement |
|---|---|---|
| `better-sqlite3` | BLOCKER | GRDB.swift / SQLite.swift |
| `hnswlib-node` | BLOCKER | swift-hnsw / Core ML similarity / Rust via XCFramework |
| `@xenova/transformers` | BLOCKER | Core ML port of all-MiniLM-L6-v2 / onnxruntime-objc |
| `sharp` | BLOCKER | Core Image / `UIImage` |
| `pdf-parse` + `react-pdf` | BLOCKER for native UI | PDFKit |
| `epubjs` / `foliate-js` | PORTABLE via WKWebView | Same JS libs inside WKWebView, OR native EPUB parser |
| `electron-updater` | BLOCKER (delete) | App Store |
| `@sentry/electron` | BLOCKER | `@sentry/react-native` or `sentry-cocoa` |
| `safeStorage` | BLOCKER | Keychain Services |
| `app.getPath('home'/'documents'/...)` | BLOCKER | UIDocumentPickerViewController bookmarks |
| `rishi://` deep links | PORTABLE | Universal Links |
| `local-file://` protocol | PORTABLE | `WKURLSchemeHandler` |
| `protocol.handle` | PORTABLE | `WKURLSchemeHandler` |
| `BrowserWindow` / menu bar | BLOCKER | Scenes, `UIKeyCommand` for iPad |
| Filesystem scanner | BLOCKER | Document picker (no recursive scan permitted) |
| Renderer HTTP server | BLOCKER (delete) | `loadFileURL(_:allowingReadAccessTo:)` |
| `ipcMain.handle` | BLOCKER | `WKScriptMessageHandler` + `evaluateJavaScript` |
| `webUtils.getPathForFile` | PORTABLE | Document picker returns NSURL |
| Node-only imports (`node:fs`, `node:crypto`, etc.) | BLOCKER | Foundation / CryptoKit |

---

*Concerns audit: 2026-06-09*
