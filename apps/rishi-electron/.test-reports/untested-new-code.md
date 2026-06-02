# Untested code from recent merges (since 2026-04-01)

Total recent src files: 424
Files still existing at HEAD: 395 (29 deleted since they were touched)
Files with 0 test references: 109 raw / **86 still-existing**
Files with 1 test reference: 110 (most are direct-test-in-sibling-`__tests__/`-dir, not weak coverage — verified)
High-risk untested behaviors selected for Phase 4.2: **11**

The coverage heuristic counts basename mentions in any `*.test.{ts,tsx}` /
`*.spec.{ts,tsx}` under `e2e/` or `src/`. A `0` strongly implies "no direct
test file" but does not mean "untested" — many zero-hit modules are reached
transitively via E2E specs or via tests that import a higher-level orchestrator.
This audit hand-classifies the 86 still-existing zero-hit files and picks the
ones whose direct logic is meaningful and uncovered.

## Subsystem: sharing (PR #253)

### High-risk untested

- `src/main/sharing/deepLink.ts` (78 lines) — parses `rishi://` URLs from
  `open-url` (macOS), first-launch argv, and second-instance argv; buffers
  tokens that arrive before the main window is ready and drains them. A bug
  here can route the user to the wrong session or silently drop join tokens.
  Pure URL parsing + queue logic; trivially testable with a fake `BrowserWindow`
  getter.

- `src/renderer/src/components/sharing/searchUsersViaWorker.ts` (28 lines) —
  builds the `onSearchUsers` callback that issues `POST /v1/users/search` to
  the worker. Bug here = host's invite UI corrupts search results or leaks the
  authToken. Already structured for test injection per its own comments.

### Tested transitively / low-risk

- `src/main/sharing/{libraryRead,reconnectStore,sharing.schemas,libraryWrite,config,authToken}.ts` —
  all show 1-2 hits but actually have direct test files in
  `src/main/sharing/__tests__/`. Coverage map underreports because tests live
  in a sibling dir.
- `src/renderer/src/sharing/{epubSyncBridge,pdfSyncBridge,sentryScope}.ts` —
  same situation (`src/renderer/src/sharing/__tests__/`).
- Sharing TSX components (`ApprovalQueueItem`, `BookPersistFailedToast`,
  `FileTransferRow`, `MicChip`, `RoleTransferToast`, `SessionEntryButton`,
  `StartSessionPopover`) — thin presentational pieces (props → JSX). The host
  state-machine logic is in `useSessionMachine` / actors which already have
  vitest coverage. Skip.

## Subsystem: player Phase 3 (PR #252)

### High-risk untested

- `src/renderer/src/hooks/player/useResumeWrite.ts` (68 lines) — debounced
  paragraph-id persistence that decides when to call `updateBookLastParagraph`.
  The module file-comment explicitly says the underlying
  `startResumeWriteSubscription` was extracted "so the writePath test … can
  drive it directly," yet no such test exists. Regression risk: lost resume
  position on reopen.

- `src/renderer/src/hooks/player/useMachineToStoreSync.ts` (125 lines) —
  mirrors XState snapshot → playerStore (playingState, activeParagraph,
  errors) and emits a visual cue on paragraph change. Deep-equal guards
  prevent re-render storms. Bug here = highlight desync, infinite re-renders,
  or stuck playingState.

- `src/renderer/src/hooks/player/useParagraphSubscriptions.ts` (89 lines) —
  forwards playerStore slices into the machine as PARAGRAPHS_UPDATED /
  NEXT/PREV_PARAGRAPHS_UPDATED with `fast-deep-equal` guards. The guards are
  the load-bearing piece: a regression here causes playing → loading flickers
  that the team has fought multiple times already.

### Tested transitively / low-risk

- `src/renderer/src/hooks/player/usePdfSeed.ts` (32 lines) — single
  fire-once seed event; small enough that an E2E PDF playback spec exercises
  it end-to-end. Optional unit test.
- `src/renderer/src/actors/{audioActor,ttsFetchActor}.ts`, all `actors/sharing/*` —
  show 1-5 hits but their basenames appear in higher-level actor / machine
  tests (`fileTransferActor`, `signalingActor`, etc.); these orchestrators
  pull in the children, so coverage is real but indirect. Skip dedicated
  tests unless a specific bug surfaces.

## Subsystem: PDF footer / virtualizer

### High-risk untested

- `src/renderer/src/components/pdf/hooks/useVirualization.tsx` (290 lines) —
  TanStack virtualizer wiring + scroll-to-page logic + container-size
  measurement that accounts for the scrollbar on Windows. Largest untested
  PDF surface and the one most likely to introduce platform-specific layout
  bugs. Worth at least a smoke render + jump-to-page test with a mock
  virtualizer.

- `src/renderer/src/components/pdf/hooks/usePdfNavigation.tsx` (79 lines) —
  reads container clientWidth and computes page sizing; the file-comment
  flags a Windows-specific phantom-scrollbar bug it fixed. No regression
  test exists; this is exactly the kind of thing that silently breaks again.

- `src/renderer/src/lib/pdfLocation.ts` (26 lines) — `parsePdfLocation` /
  `formatPdfLocation` parse the "page:offset" persisted location string and
  must keep accepting the bare-page legacy format. Pure functions, trivial
  test, high blast radius (book reopens to wrong scroll position).

### Tested transitively / low-risk

- `pdf/utils/footerStrategies/suffixStrategy.ts` — one-line adapter around
  the already-tested `findRepeatingPageSuffix`. Skip.
- `pdf/hooks/{useUpdateCoverIMage,useWindowSize,useCurrentPageNumber,useSetupMenu}.tsx` —
  6-25 line glue hooks; the underlying writes (`updateStoredCoverImage`)
  already have direct tests. Skip.

## Subsystem: other (main, db, ipc, renderer modules)

### High-risk untested

- `src/main/database/repair.ts` (21 lines) — idempotent boot-time SQL that
  rewrites `kind='mobi'` rows whose filepath ends in `.azw3`. Easy to break
  with a typo, runs on every boot, affects book rendering. One SQL-fixture
  test is cheap insurance.

- `src/main/ipc/util.ts` (35 lines) — `shell:openExternal` allow-lists
  `http:` / `https:` / `mailto:` protocols. **This is the security boundary
  that stops a renderer XSS from launching `file://`, `vscode://`, etc.** A
  regression here is a renderer-to-OS escape. Mandatory unit test.

- `src/main/ipc/sync.schemas.ts` (161 lines) — zod schemas that replaced
  `as string`/`as number` casts in the cloud-sync conflict resolver. The
  file-comment spells out the bug they fixed (malformed cloud payload
  corrupting SQLite NOT NULL columns). Tested transitively by
  `sync-validation.test.ts` (which drives `_applyBookConflictWithDb` &c.),
  but the schemas themselves deserve direct contract tests for each atom
  (`truthyAsInt`, `optionalNullableString`, `optionalTimestampString`)
  because the transitive tests only cover the happy path.

- `src/main/utils/rendererServer.ts` (207 lines) — local HTTP server
  serving `out/renderer/` in production with explicit path-traversal
  rejection (the file-comment says "any request that escapes the renderer
  root is rejected with 403"). Path-traversal logic is exactly the kind of
  thing that needs an adversarial test. High blast radius (LAN access to
  arbitrary host files if it regresses).

- `src/renderer/src/modules/epub-page-tracker.ts` (276 lines) — zustand
  store with a locIndex→page lookup map that prevents counter drift on
  backward navigation in epub.js. Persisted per-book. Bug class is "page
  numbers drift" — silent, user-visible, and the kind of thing reviewers
  miss. Pure store logic, easy to unit-test with the documented locIndex
  sequences from the file header.

- `src/renderer/src/hooks/useFileOpenHandler.ts` (61 lines) — handles OS
  "Open With" file paths, runs `getBookImportService().importBatch`, guards
  re-entrancy with an `inFlight` ref, drains pre-listener-mount paths from
  `getPendingOpenFiles()`, opens the first successful book in a new
  BrowserWindow. The re-entrancy guard + first-success selection are
  testable contract; bugs cause double-imports or wrong-book opens.

### Tested transitively / low-risk

- `src/main/ipc/_syncFields.ts` (18 lines) — two trivial constants/helpers
  for sync-dirty defaults; exercised by every sync IPC handler that writes
  a row. Skip.
- `src/main/ipc/books-extra.ts` (22 lines) — three drizzle one-liners
  (`getSyncId`, `updateFilepath`, `updateFileHash`); transitively covered
  by sync E2E. Skip dedicated.
- `src/main/windows/createBrowserWindow.ts` (101 lines) — Electron
  `BrowserWindow` factory; nearly all config is declarative. The webSecurity
  conditional is the only behavior worth verifying, and the e2e harness
  already opens book windows. Skip.
- `src/renderer/src/modules/Mutex.ts` (23 lines) — appears unused at HEAD
  (no `import Mutex` matches under `src/`). Dead code; flag for deletion,
  not for testing.
- `src/renderer/src/modules/{ipc_handles,ipc_handel_functions}.ts` — TTS
  event enum + Sentry-wrapped delegate; the wrapped function has its own
  unit test elsewhere. Skip.
- `src/renderer/src/modules/{readyChime,thinkingSound}.ts` — pure Web Audio
  side-effect modules (`AudioContext`, `OscillatorNode`). No logic worth
  asserting in jsdom; coverage would just mock everything. Skip.
- `src/renderer/src/modules/{epub_constants,shouldDebug}.ts`,
  `src/renderer/src/utils/{debugLog,errorDump,stateDump,is_dev}.ts` — dev /
  debug instrumentation, constants, and `IS_DEV` short-circuits. Low
  business-logic value. Skip.
- `src/renderer/src/lib/languages.ts` (53 lines) — static ISO-639-1
  whitelist + label map; type system already enforces. Skip.
- `src/renderer/src/helpers/ptsToPx.ts` (15 lines) — `pts * 96 / 72`; the
  arithmetic is the spec. A one-line test is harmless but not high-risk.
- `src/renderer/src/hooks/{useBookSearch,useConnectivity,useVoiceInput,
  use-mobile,reader/useVisibleEpubIframe.ts}` — read-side React hooks
  whose behaviour is exercised by E2E (search, voice chat, EPUB rendering)
  or by the parent component's tests. Skip dedicated unit tests unless a
  bug surfaces.
- Lazy route files (`routes/*.lazy.tsx`, `routes/settings/account.tsx`,
  `routeTree.gen.ts`, `bootstrap-app.tsx`, `polyfills.ts`,
  `config/worker-url.ts`, `vite-env.d.ts`, `electron.d.ts`) — wiring,
  generated code, type declarations. Skip.
- `src/renderer/src/components/ui/*` (`badge-variants`, `carousel`,
  `dropdown-menu`, `IconButton`, `Radio`, `scroll-area`, `separator`,
  `sidebar-context`, `skeleton`, `slider`, `Spinner`) — shadcn-style
  primitives. Not in scope for behavior tests.
- Auth/chat/search/tutorial/reader UI components zero-hits (`ClerkAuth`,
  `SignInBanner`, `ChatInput`, `ChatPanel`, `SourceChip`, `SearchPanel`,
  `ReaderSettings`, `ReaderToolbar`, `BookmarkButton`, `BookmarksList`,
  `NetworkBanner`, `LoginButton`, `UpdateMenu`, `TourProvider`,
  `SyncStatusIndicator`, `DjvuView`, `BackButton`, `providers.tsx`,
  `queryClient.ts`, `react-reader/components/TocToggleButton`,
  `pagecurl/usePageCurl`) — presentational or thin glue around tested
  services. Skip unless specific logic surfaces.
- 29 files in the recent-src list have been deleted since they were
  touched (e.g. `modules/ttsCache`, `ttsQueue`, `ttsService`,
  `voiceChatService`, `process_epub`, `sync-adapter`, `sync-triggers`,
  `pdf/components/text-extractor`, `pdf/components/background-page`,
  `pdf/hooks/useThumbnailVirtualizer`, ...). Skipped — not in HEAD.

## Methodology

- Recent files enumerated via `git log --since='2026-04-01'` over
  `src/**/*.ts(x)`, with test/spec files filtered out.
- Test references = basename appearing as a whole word in any
  `*.test.{ts,tsx}` / `*.spec.{ts,tsx}` under `e2e/` or `src/`. Counted
  with `grep -l -E "\bbase\b"`.
- Files since-deleted from HEAD (29 of 424) are excluded from the
  high-risk audit even when zero-hit.
- 1-hit files were spot-checked: most are covered by a sibling
  `__tests__/<file>.test.ts`, which is the project's preferred layout.
- Hand-audit excluded trivial glue (re-exports, constants, pure type
  definitions, presentational components without state).
- Selection bias: high-risk = nontrivial logic + security/data-integrity
  surface + plausible regression scenario. The 11 selected items aim at
  risk reduction, not coverage chasing.
