# Codebase Structure

**Analysis Date:** 2026-06-09

**Target codebase:** `apps/rishi-electron` (the existing Electron desktop reader). This map gives the iOS team a feature-by-feature inventory so each module can be mirrored in SwiftUI.

## Directory Layout

```
apps/rishi-electron/
├── src/
│   ├── main/                       # Node-side Electron main process
│   │   ├── index.ts                # App entry: lifecycle, single-instance, protocols, windows
│   │   ├── contextMenu.ts          # Right-click menu in reader windows
│   │   ├── auth/                   # OAuth/PKCE, session encryption, IPC handlers
│   │   ├── database/               # SQLite open, schema, migrations, queries, repair
│   │   ├── vectordb/               # HNSW vector index + embedding model load
│   │   ├── ipc/                    # All `ipcMain.handle` registrations (per-domain files)
│   │   ├── menu/                   # Native application menu builder + accelerators
│   │   ├── windows/                # BrowserWindow factory + WindowManager
│   │   ├── sharing/                # P2P sharing config, JWT, deep links, transferred-book persistence
│   │   └── utils/                  # Atomic write, error helpers, renderer-server (file://-replacement), Sentry
│   ├── preload/                    # Privileged bridge between main and renderer
│   │   ├── index.ts                # `contextBridge.exposeInMainWorld('electron'/'api', ...)`
│   │   ├── ipc-contract.ts         # SINGLE SOURCE OF TRUTH for IPC channels (typed)
│   │   ├── types.ts                # `ElectronAPI` derived from contract via `ChannelToMethod`
│   │   └── windowIdentity.ts       # Parse `--window-identity=...` argv flag
│   └── renderer/
│       ├── index.html
│       └── src/                    # React 19 SPA
│           ├── main.tsx            # Renderer entry: RouterProvider + Providers
│           ├── routes/             # TanStack Router file-based routes
│           ├── components/         # React components by domain
│           ├── stores/             # Zustand stores (UI/runtime state)
│           ├── machines/           # XState state machines
│           ├── actors/             # XState actors invoked by machines
│           ├── services/           # Business-logic services (port-injection pattern)
│           ├── modules/            # Lower-level helpers and adapters
│           ├── hooks/              # React hooks
│           ├── lib/                # Renderer API client + utilities
│           ├── sharing/            # Renderer glue for P2P sharing (sync bridges, Sentry scope)
│           ├── testing/            # Test seams (`expose-stores`, sharing-test-hooks)
│           ├── types/              # Renderer-only types (highlight, conversation, foliate-js shims)
│           ├── themes/             # Reader color themes
│           ├── helpers/, utils/, models/, config/  # Misc
│           ├── styles/globals.css  # Tailwind v4 entry
│           └── config.json         # Renderer-only runtime config (worker URLs)
├── e2e/                            # Playwright end-to-end specs
├── scripts/                        # Build / native-ABI helper scripts
├── build/, resources/              # Electron-builder assets
├── electron.vite.config.ts         # main/preload/renderer build configs
├── electron-builder.yml            # Packaging, fileAssociations, protocols, signing
├── package.json
└── pnpm-workspace.yaml
```

## Directory Purposes

### Main process (`src/main/`)

**`src/main/index.ts`** — Bootstrap. Owns: Sentry init, `app.whenReady`, `app.requestSingleInstanceLock`, `open-file`, `second-instance`, custom `local-file://` protocol, render-process-gone recovery, `bootstrapMenuAndWindows`. ~650 lines; the place to start when tracing any lifecycle question.

**`src/main/auth/`**
- `auth-service.ts`: PKCE pair generation, `/desktop/start` + `/desktop/poll` against `https://api.fidexa.org`, magic-link + Google OAuth flows, session listener fan-out.
- `pkce.ts`: PKCE primitives (`generatePkcePair`).
- `session-store.ts`: Read/write encrypted session via `safeStorage` to `userData/session.enc`; atomic writes.
- `index.ts`: Registers `auth:*` IPC handlers and `'session-changed'` broadcasts.

**`src/main/database/`**
- `index.ts`: `initDatabase()` opens `<userData>/rishi.db` with `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`.
- `schema.ts`: drizzle table definitions — `books`, `chunk_data`, `highlights`, `bookmarks`, `conversations`, `messages`, `sync_meta`.
- `migrations.ts`: schema migration runner.
- `queries.ts`: raw `better-sqlite3` queries called by IPC handlers.
- `repair.ts`: one-shot repair for AZW3 books mis-tagged as MOBI.

**`src/main/vectordb/`**
- `index.ts`: HNSW (hnswlib-node) wrapper — `saveVectors`, `searchVectors`, `rebuildIndexFromChunks`, `deleteIndex`. 384-dim cosine. Atomic save via tmp+rename. Corruption recovery.
- `embeddings.ts`: `@xenova/transformers` MiniLM embedding pipeline (`generateEmbeddings`).

**`src/main/ipc/`** — One file per domain. All call `handle()` from `preload/ipc-contract.ts` so types stay in sync.
- `index.ts`: `registerAllIpcHandlers()` calls every per-domain registrar.
- `books.ts`, `books-extra.ts`: CRUD for books.
- `chunks.ts`: chunk_data CRUD.
- `search.ts`: full-text + vector-result-to-chunk lookup.
- `vectors.ts`: embed/save/search/has/process-job.
- `formats.ts`: EPUB (JSZip-based parse, no DOM), PDF (`pdf-parse`), MOBI/AZW3.
- `fs.ts`: file size, unzip, copy, hardlink-or-copy (TTS cache), userData path; sandbox-checks paths against `app.getPath('userData')`.
- `scanner.ts`: background folder scanning for default book folders.
- `auth.ts`: legacy cached-user store (clear/get/save).
- `debug.ts`: error/state dump files + append-only debug log in userData.
- `store.ts`: generic key/value settings store.
- `util.ts`: `isDev`, `getDevBypassSecret`, `getOsInfo`.
- `dialog.ts`: native open/message dialogs.
- `bookmarks.ts`, `highlights.ts`, `conversations.ts`: CRUD for reader annotations + chat.
- `sync.ts` + `sync.schemas.ts`: getDirty / markClean / applyConflict / upsert / lastVersion (per entity), with zod schemas for remote payloads.
- `updater.ts` + `updaterPref.ts`: electron-updater plus the user preference for auto-check.
- `sharing.ts`: 8 channels (getSigningJwt, saveTransferredBook, discardTransferredBook, hasBookFile, readBookBytes, getConfig, readReconnect/writeReconnect/clearReconnect).

**`src/main/menu/`** — Native menu.
- `commands.ts`: `MenuContext` + `MenuCommand` types (kind, format, theme, recentBooks, openBookTitles, tocOpen, thumbsOpen, dualPage, isReading, bookmarks).
- `accelerators.ts`: per-platform keyboard shortcuts.
- `menuBuilder.ts`: `buildMenu(ctx, dispatch)` returning `MenuItemConstructorOptions[]`.
- `installMenu.ts`: `MenuInstaller` — holds the current context, rebuilds + installs on `setContext`.

**`src/main/windows/`**
- `createBrowserWindow.ts`: factory. Picks size by identity. Sets `titleBarStyle: 'hiddenInset'`, `contextIsolation: true`, `sandbox: false`, `nodeIntegration: false`. Passes `--window-identity=...` flag. Book windows get `webSecurity: false` (epub.js srcdoc iframes). Intercepts `close` on book windows to flush pending saves via `window.__rishi.flushPendingSaves()`.
- `windowManager.ts`: `WindowManager` keeps maps of library/settings/book windows + open/close/focus + closed-listener cleanup.

**`src/main/sharing/`**
- `deepLink.ts`: registers `rishi://` protocol, parses `rishi://sharing/join?t=<token>`, routes to the library window or buffers.
- `authToken.ts`: signs JWT for the sharing worker.
- `config.ts`: returns `wsBaseUrl`, `workerBaseUrl`, `iceServers` (TURN/STUN).
- `libraryWrite.ts`: `saveTransferredBook`, `hasBookFile`, `discardTransferredBook` — writes shared books to `<userData>/shared-reading-library/<contentHash>.<ext>`, inserts books row with `source='shared-session'`.
- `libraryRead.ts`: `readBookBytes` — verifies on-disk SHA-256 matches `contentHash` before returning bytes for outbound transfer.
- `reconnectStore.ts`: persists `{ sessionId, reconnectToken, wsUrl, reservedUntil, storedAt }` per user; survives crashes.
- `sharing.schemas.ts`: zod schemas validating every renderer-supplied payload.

**`src/main/utils/`**
- `atomicWrite.ts`: tmp+rename helper used everywhere persistence matters.
- `errors.ts`: `errorMessage(unknown) -> string`.
- `rendererServer.ts`: tiny local HTTP server for production renderer assets (replaces `file://` to avoid Chromium quirks).
- `sentry.ts`: `initMainSentry`, `captureError`.

### Preload (`src/preload/`)

- **`index.ts`** — Binds every IPC channel to a method on `window.electron` (or `window.api.auth` for the better-auth surface). Adds non-invoke helpers: `on`/`once`/`send`, `windowIdentity`, `onMenuCommand`, `setMenuContext`, `refreshMenu`. Routes file-path drag/drop via `webUtils.getPathForFile`.
- **`ipc-contract.ts`** — `IpcContract` map. Helpers: `invoke<K>(channel, ...args)` (renderer), `handle<K>(channel, fn)` (main). Sharing types defined here too (`SharingSignedJwt`, `SharingConfig`, `SharingSaveTransferredBookParams`, ..., `SharingReconnectPayload`).
- **`types.ts`** — `ChannelToMethod` map + `ElectronAPI` + `Api` (the `auth` namespace). All method signatures derived from the contract; compile-time check enforces every channel has a binding.
- **`windowIdentity.ts`** — Pure parser for `--window-identity=library|settings|book:<id>`.

### Renderer (`src/renderer/src/`)

**`routes/`** — TanStack Router file routes (hash history).
- `__root.tsx`: hydrate auth, window-identity guard (legacy `/books/N` in library window → spawn book window; book window forced to `/books/<id>`), theme publishing to main, sync start, menu commands.
- `index.lazy.tsx`: library landing → `<FileComponent />`.
- `books.$id.lazy.tsx`: reader screen; fetches book, dispatches PDF/EPUB/AZW3 viewer based on `book.kind`.
- `settings/account.tsx`: account settings (sign-out, delete account, MAS-aware).
- `routeTree.gen.ts`: generated.

**`components/`** by feature domain:
- `library/`: cover cache (`coverCache.ts`), selection bar, delete dialog, selection hook.
- `reader/`: shared reader chrome — `ReaderOverlayControls.tsx`, `ReaderTOC.tsx`, `TTSVisualCue.tsx`.
- `react-reader/`: epubjs-based viewer (imported from `react-reader` + custom subdirs `components/`, `epub_viewer/`, `NavigationArrows.tsx`, `TableOfContents.tsx`).
- `epub/`: `EpubView.tsx`, locs cache, TTS highlight reconciler, debounced location save, TOC→chapters.
- `pdf/`: `PdfView.tsx`, `HighlightLayer.tsx`, `components/` (pdf-page, thumbnail-sidebar), `hooks/` (usePdfNavigation, useScrolling, useThumbnailVirtualizer, useUpdateCoverImage, useVirtualization, useWindowSize), `subscriptions/bus.ts`, `utils/footerStrategies`.
- `azw3/`: AZW3/MOBI reader (foliate-js).
- `mobi/`: legacy MOBI view (dead code, kept for rollback).
- `pagecurl/`: page-curl animation for EPUB transitions.
- `chat/`: `AIChatOrb.tsx`, `ChatPanel.tsx`, `ChatMessage.tsx`, `ChatInput.tsx`, `SourceChip.tsx`, `VoiceChatLauncher.tsx`.
- `auth/`: `LoginButton.tsx`, `SignInModal.tsx`, `SignInBanner.tsx`, `WelcomeModal.tsx`, `PremiumFeatureDialog.tsx`, `features.ts` (gated-feature definitions).
- `highlights/`: `HighlightsPanel.tsx`, `SelectionPopover.tsx`, `HighlightActionPopover.tsx`, `NoteEditor.tsx`, click handler, position calc.
- `bookmarks/`: `BookmarksList.tsx`.
- `tts/`: `TTSControls.tsx`.
- `sharing/`: full P2P UI — `SessionPanel.tsx`, `SessionEntryButton.tsx`, `SharingSessionOverlay.tsx`, `InvitePanel.tsx`, `StartSessionPopover.tsx`, `ParticipantTile.tsx`, `FileTransferRow.tsx`, `ApprovalQueueItem.tsx`, `ApprovalWaitingScreen.tsx`, `HostSuspendedBanner.tsx`, `KickedDialog.tsx`, `MicChip.tsx`, `BookPersistFailedToast.tsx`, `RoleTransferToast.tsx`, `SessionEndedKeepBooksDialog.tsx`, `searchUsersViaWorker.ts`.
- `navigation-history/`: history nav UI.
- `tutorial/`: onboarding tour (`TourProvider`, `TourTooltip`, `SpotlightOverlay`, `ContextualHint`).
- `search/`: in-book search UI.
- `ui/`: shadcn-style primitives (Button, dialog, dropdown-menu, popover, scroll-area, sheet, sidebar, slider, tooltip, etc.).
- Top-level: `FileComponent.tsx` (library grid), `BookDiscoveryModal.tsx`, `HelpMenu.tsx`, `LoginButton.tsx`, `NetworkBanner.tsx`, `Loader.tsx`, `ErrorBoundary.tsx`, `providers.tsx`, `queryClient.ts`, `SyncStatusIndicator.tsx`, `IndexingStatusIndicator.tsx`.

**`stores/`** — Zustand. Notable:
- `authStore.ts`: user, hydrated flag, welcome-seen, sign-in modal state.
- `epubStore.ts` / `pdfStore.ts`: per-format current book + navigation state.
- `playerStore.ts`: TTS playback (current paragraph, last-played paragraph).
- `chatStore.ts` + `initBookChatSubscription.ts`: chat messages + per-book subscription wiring.
- `indexingStore.ts`: indexing progress per book.
- `prefsStore.ts`: user preferences (voice-chat language, theme, etc.).
- `selectionStore.ts`: current text selection in the reader.
- `tutorialStore.ts`: tour completion.
- `navStore.ts`: navigation history.

**`machines/`** — XState v5.
- `playerMachine.ts`: TTS playback FSM. Invokes `audioActor`, `ttsFetchActor`, format-specific `view` actor. States: idle/loading/playing/paused/error with retry.
- `pdfReaderMachine.ts`: PDF reader state.
- `navMachine.ts`: in-book navigation.
- `sessionMachine.ts`: auth session machine.
- `connectivityMachine.ts`: online/offline FSM.
- `navigationHistory/`: history machine.

**`actors/`** — XState actors.
- `audioActor.ts`: wraps a singleton `HTMLAudioElement`.
- `epubViewActor.ts` / `pdfViewActor.ts`: format-specific scroll/highlight-to-paragraph actors.
- `viewActor.ts`: shared view-actor command type.
- `ttsFetchActor.ts`: `fromPromise` actor that fetches a single paragraph's audio.
- `sharing/`: actors used by the sharing flow.

**`services/`** — Business-logic services with port DI. Wired in `services/index.ts`.
- `book-import/`: file → metadata → DB save → embed → vector save pipeline. `dispatch.ts`, `emitter.ts`, `importer.ts`, `indexer.ts`, `scanner-adapter.ts`, `service.ts`, `types.ts`.
- `sync/`: push dirty + pull remote, with debounce, connectivity gating, conflict apply. `adapter.ts`, `debounce.ts`, `emitter.ts`, `service.ts`, `types.ts`.
- `rag/`: semantic + text search (HNSW + SQLite). `service.ts`, `types.ts`.
- `tts/`: re-exports `@rishi/shared/tts` plus electron-specific `getVisualCueEmitter` and `resolveParagraphElement` for the active epub frame.
- `connectivity/`: online state + subscribers + `useIsOnline` hook.
- `indexing/`: `index-program.ts` (program of work), `text-extraction.ts`.
- `reader-cache/`: in-memory caches (`cache.ts`, `epub-cache.ts`, `pdf-cache.ts`) keyed by book ID, with `evictPdf`/`evictEpub`.

**`modules/`** — Helpers not shaped as services.
- `auth.ts`: `getAuthToken()` — pulls from `window.api.auth.getToken()`.
- `books.ts`: `copyBookToAppData` and friends.
- `file-sync.ts`: hash + upload book file to R2 via worker.
- `embed-fallback.ts`: renderer-side embedding with main-side IPC fallback.
- `pdf-locator.ts`: page+offset position model.
- `epubwrapper.ts`: thin wrapper over `epubjs`.
- `epub-page-tracker.ts`: page-number tracker for EPUB.
- `cfi-to-paragraph.ts`: CFI → paragraph index resolution.
- `note-icon-overlay.ts`: in-text note icons.
- `highlight-storage.ts`, `bookmark-storage.ts`, `highlight-actions.ts`: storage adapters.
- `handleDroppedFiles.ts`, `chooseFiles.ts`: drag/drop + file picker.
- `buildRealtimeAgent.ts`: OpenAI realtime agent setup.
- `readyChime.ts`, `thinkingSound.ts`: SFX.
- `ttsPrefetch.ts`: prefetch TTS audio for next paragraphs.
- `updater.ts`: renderer-side updater UI flow.
- `pageCapture/`: capture page image (for AI inspection).
- `resolve-live-selection/`: live text selection resolution.
- `read-aloud-from/`: "read aloud from here" feature.
- `Mutex.ts`: simple promise-based mutex.

**`hooks/`** — React hooks. Notable: `useHydrateAuth`, `useFileOpenHandler` (consumes `'open-files'` channel), `useMenuCommands` (subscribes to `'menu:command'`), `useStartupUpdateCheck`, `usePostImportSync`, `useChat`, `useVoiceInput`, `useNavMachine`, `useSessionMachine`, `usePlayerMachine`, `useRequireAuth`, `useEngagementDetector`, `usePdfHighlights`, `usePdfReader`, `usePdfTextSelection`, `usePdfReadAloudFromSelection`, `useTtsHighlightReconciler`, `useUndoableHighlightShortcut`, `useNavigationHistory`, `useBookSearch`, `useMobile`.
- `hooks/reader/`: per-reader hooks.
- `hooks/player/`: TTS player hooks.

**`lib/`**
- `api.ts`: typed wrappers around IPC + worker REST calls (`getBooks`, `deleteBook`, `convertFileSrc`, `getBook`, `getRealtimeClientSecret`, `transcribeAudio`, `workerFetch`).
- `utils.ts`: misc utilities.
- `languages.ts`: language list for voice chat.
- `pdfLocation.ts`: PDF position helpers.
- `sharing-flag.ts`: sharing-feature flag.
- `visualHeuristic.ts`: heuristics for visual analysis.

**`sharing/`** — Sharing-specific renderer glue.
- `epubSyncBridge.ts`: bridge EPUB reader state to the sharing peer.
- `pdfSyncBridge.ts`: same for PDF.
- `sentryScope.ts`: scoped Sentry tags for sharing flows.

**`testing/`** — Test seams. `expose-stores.ts` (exposes Zustand stores on `window` in E2E builds), `fakeRtcAdapter.ts`, `sharing-test-hooks.ts`.

**`types/`** — Renderer-only types. `conversation.ts`, `highlight.ts`, `foliate-js.d.ts`, barrel `index.ts`.

**`themes/`** — Reader color themes (gray, white, yellow + common).

**`config/`** — `worker-url.ts` (resolves the Cloudflare Worker base URL).

## Key File Locations

**Entry Points:**
- Main: `src/main/index.ts`
- Preload: `src/preload/index.ts`
- Renderer: `src/renderer/src/main.tsx`
- Library route: `src/renderer/src/routes/index.lazy.tsx`
- Reader route: `src/renderer/src/routes/books.$id.lazy.tsx`
- Settings route: `src/renderer/src/routes/settings/account.tsx`

**Auth:**
- Main service: `src/main/auth/auth-service.ts`
- PKCE: `src/main/auth/pkce.ts`
- Encrypted session (safeStorage): `src/main/auth/session-store.ts` → `<userData>/session.enc`
- IPC registration: `src/main/auth/index.ts`
- Renderer hook: `src/renderer/src/hooks/useHydrateAuth.tsx`
- Auth store: `src/renderer/src/stores/authStore.ts`
- Auth token getter (renderer): `src/renderer/src/modules/auth.ts`

**IPC contract:**
- Single source: `src/preload/ipc-contract.ts`
- Renderer API shape: `src/preload/types.ts`
- Preload bindings: `src/preload/index.ts`
- All main-side handlers registered from: `src/main/ipc/index.ts`

**Reader engine:**
- EPUB: `src/renderer/src/components/epub/EpubView.tsx`, `src/renderer/src/modules/epubwrapper.ts`, `src/renderer/src/components/react-reader/`
- PDF: `src/renderer/src/components/pdf/PdfView.tsx`, `src/renderer/src/components/pdf/components/`, `src/renderer/src/components/pdf/hooks/`
- AZW3/MOBI: `src/renderer/src/components/azw3/Azw3View.tsx` (uses `foliate-js`)
- Format parsing (main): `src/main/ipc/formats.ts`
- Position tracking: `src/renderer/src/modules/pdf-locator.ts`, `src/renderer/src/modules/epub-page-tracker.ts`, `src/renderer/src/modules/cfi-to-paragraph.ts`

**AI / Chat:**
- Chat UI: `src/renderer/src/components/chat/ChatPanel.tsx`, `ChatInput.tsx`, `ChatMessage.tsx`, `AIChatOrb.tsx`
- Chat store: `src/renderer/src/stores/chatStore.ts`
- Chat hook: `src/renderer/src/hooks/useChat.ts`
- Voice chat: `getVoiceChatService()` in `src/renderer/src/services/index.ts` (uses `@rishi/shared/voice-chat`)
- Realtime agent builder: `src/renderer/src/modules/buildRealtimeAgent.ts`
- RAG: `src/renderer/src/services/rag/service.ts`
- DB tables: `conversations`, `messages` in `src/main/database/schema.ts`
- IPC: `src/main/ipc/conversations.ts`, `src/main/ipc/sync.ts` (for `messages:*`)

**TTS:**
- Service: `src/renderer/src/services/tts/index.ts` (re-exports `@rishi/shared/tts`)
- Player FSM: `src/renderer/src/machines/playerMachine.ts`
- Actors: `src/renderer/src/actors/audioActor.ts`, `ttsFetchActor.ts`, `epubViewActor.ts`, `pdfViewActor.ts`
- Visual cue: `src/renderer/src/components/reader/TTSVisualCue.tsx`
- Prefetch: `src/renderer/src/modules/ttsPrefetch.ts`
- Cache lives on disk in `<userData>` via `fs:writeFile` + `fs:linkOrCopyFile`

**Sync:**
- Service: `src/renderer/src/services/sync/service.ts`
- Adapter: `src/renderer/src/services/sync/adapter.ts`
- Engine: `@rishi/shared/sync-engine` (workspace package)
- File sync (R2): `src/renderer/src/modules/file-sync.ts`
- DB schemas: `is_dirty`, `is_deleted`, `sync_version`, `sync_id` columns on books/highlights/conversations/messages; `sync_meta` table
- IPC handlers: `src/main/ipc/sync.ts`
- Status indicator: `src/renderer/src/components/SyncStatusIndicator.tsx`

**Billing gate:**
- Outbound auth headers (`Authorization: Bearer` + `X-Dev-Bypass`): set per call in `src/renderer/src/services/sync/service.ts` (`createApiFetch`), `src/renderer/src/services/index.ts` (`resolveTtsAuth`), `src/renderer/src/lib/api.ts` (`getAuthHeaders` + `workerFetch`).
- Dev bypass secret: `src/main/ipc/util.ts` → `util:getDevBypassSecret`.
- Premium-feature dialog: `src/renderer/src/components/auth/PremiumFeatureDialog.tsx`, `features.ts`.

**Storage:**
- SQLite: `<userData>/rishi.db` opened in `src/main/database/index.ts`
- Vector indices: `<userData>/vectordb/<bookId>-vectordb.hnsw` managed by `src/main/vectordb/index.ts`
- Imported book files: copied via `src/renderer/src/modules/books.ts` (`copyBookToAppData`) to `<userData>/`
- Shared-session books: `<userData>/shared-reading-library/<contentHash>.<ext>` in `src/main/sharing/libraryWrite.ts`
- Encrypted session: `<userData>/session.enc` via `src/main/auth/session-store.ts`
- TTS audio cache: under `<userData>` via `fs:*` IPC (managed by `@rishi/shared/tts`)
- Debug dumps: `error-dump.json`, state dump, append log under `<userData>` via `src/main/ipc/debug.ts`

**Deep links:**
- `rishi://sharing/join?t=<token>`: `src/main/sharing/deepLink.ts`
- `open-file` (macOS) + argv (Win/Linux): `src/main/index.ts` (`deliverOpenFiles`)
- Renderer handler: `src/renderer/src/hooks/useFileOpenHandler.ts`
- Custom protocol for local file streaming: `local-file://` registered in `src/main/index.ts` (`registerLocalFileProtocol`)

**Windowing:**
- Factory: `src/main/windows/createBrowserWindow.ts`
- Manager: `src/main/windows/windowManager.ts`
- Identity flag parser: `src/preload/windowIdentity.ts`
- Route enforcement: `src/renderer/src/routes/__root.tsx` (the `enforce` effect)

**Menu (native):**
- Builder: `src/main/menu/menuBuilder.ts`
- Installer: `src/main/menu/installMenu.ts`
- Commands/context types: `src/main/menu/commands.ts`
- Accelerators: `src/main/menu/accelerators.ts`
- Renderer dispatcher: `src/renderer/src/hooks/useMenuCommands.ts`

**P2P Sharing:**
- Renderer overlay: `src/renderer/src/components/sharing/SharingSessionOverlay.tsx`
- Bridges: `src/renderer/src/sharing/epubSyncBridge.ts`, `pdfSyncBridge.ts`
- Actors: `src/renderer/src/actors/sharing/*`
- Protocol package: `@rishi/sharing-protocol` (workspace)
- Main-side: `src/main/sharing/*`

## Naming Conventions

**Files:**
- Components: `PascalCase.tsx` (`EpubView.tsx`, `ChatPanel.tsx`, `SessionPanel.tsx`).
- Hooks: `useFooBar.ts` (camelCase prefixed with `use`).
- Services / stores / machines / modules: `camelCase.ts` (`authStore.ts`, `playerMachine.ts`, `file-sync.ts`).
- Hyphenated file names appear where the term is multi-word and historically Unix-ish (`file-sync.ts`, `cfi-to-paragraph.ts`, `read-aloud-from/`).
- Tests: co-located `*.test.ts`/`*.test.tsx` (and `*.coverage.test.ts` for machines that want explicit coverage).
- Schemas (zod): `*.schemas.ts` (e.g. `sync.schemas.ts`, `sharing.schemas.ts`).

**Directories:**
- Renderer feature folders: lowercase, often hyphenated for multi-word (`book-import/`, `reader-cache/`, `navigation-history/`, `react-reader/`).
- UI primitives live in `components/ui/` (shadcn-style).

**IPC channel names:** `namespace:action` (`books:getAll`, `sync:getDirtyBooks`, `sharing:saveTransferredBook`, `auth:start-magic-link`). Map to flat camelCase methods on `window.electron` via `ChannelToMethod` in `src/preload/types.ts`.

**Stores:** suffix `Store` (`authStore`, `epubStore`, `playerStore`, …) — Zustand hook exported as `useFooStore`.

**XState machines:** suffix `Machine` (`playerMachine`, `pdfReaderMachine`, …).

**XState actors:** suffix `Actor` (`audioActor`, `ttsFetchActor`, …).

**Services:** factory `createFooService(deps): FooService` + singleton accessor `getFooService()` in `src/renderer/src/services/index.ts`.

## Shared Types / Contracts Between Main and Renderer

The contract lives **only** in the preload package — never duplicate it.

- **`src/preload/ipc-contract.ts`**: `IpcContract` map (channels → `{ args, returns }`). Plus sub-shapes for sharing (`SharingSignedJwt`, `SharingConfig`, `SharingSaveTransferredBookParams`, `SharingReadBookBytesParams`, `SharingReconnectPayload`, etc.) and sync (`SyncConflictPayload`, `SyncRemotePayload`, `SyncRowRecord`).
- **`src/preload/types.ts`**: `Book`, `BookInsertable`, `BookData`, `BookOutline`, `PageData`, `ChunkDataInsertable`, `TextSearchResult`, `SearchResult`, `EmbedParam`, `EmbedResult`, `VectorData`, `FileSizeCheck`, `User`, `ErrorDump`, `BookmarkRow`, `HighlightRow`, `ConversationRow`, `MessageRow`, `AuthUser`. `ElectronAPI` and `Api` are derived from `IpcContract` + `ChannelToMethod`.
- **`src/preload/windowIdentity.ts`**: `WindowIdentity` discriminated union — `{ kind: 'library' } | { kind: 'book'; bookId: number } | { kind: 'settings' }`. Parsed in preload, used in renderer (`__root.tsx`), and constructed in main (`windowManager.ts`).

Workspace packages also share types between processes/apps:
- **`@rishi/shared`** (`packages/shared`): TTS service factory, voice-chat service factory, sync engine. Imported by the renderer; some types reach main indirectly via shared sync payloads.
- **`@rishi/sharing-protocol`** (`packages/sharing-protocol`): WebSocket frame schemas for the P2P sharing worker.

## Where to Add New Code

**New IPC channel:**
1. Add an entry to `IpcContract` in `src/preload/ipc-contract.ts`.
2. Add the method name to `ChannelToMethod` in `src/preload/types.ts`.
3. Bind it on `electronAPI` in `src/preload/index.ts`.
4. Register the main-side handler in the appropriate `src/main/ipc/<domain>.ts` (and add to `registerAllIpcHandlers` if it's a new domain file).

**New reader feature (e.g., annotations):**
- DB schema: `src/main/database/schema.ts` (new table) + migration in `src/main/database/migrations.ts`.
- Queries: `src/main/database/queries.ts`.
- IPC: new file under `src/main/ipc/`, registered in `src/main/ipc/index.ts`.
- Renderer UI: new folder under `src/renderer/src/components/<feature>/`.
- State: new Zustand store under `src/renderer/src/stores/` if it's runtime state, or pure module under `src/renderer/src/modules/`.
- Sync wiring: add `is_dirty`/`sync_version`/`is_deleted` columns + handler entries in `src/main/ipc/sync.ts` + adapter case in `src/renderer/src/services/sync/adapter.ts`.

**New format viewer:** dispatch in `src/renderer/src/routes/books.$id.lazy.tsx`; create `src/renderer/src/components/<format>/`; add a view actor under `src/renderer/src/actors/`; parse metadata in `src/main/ipc/formats.ts`.

**Shared logic across mobile + electron:** put it in `packages/shared/` and import from `@rishi/shared/<subpath>`. Do not refactor in place — copy and adapt (`feedback_electron_only.md`).

**New native dependency:** declare in `package.json`; add to `onlyBuiltDependencies` if it has a native binding; if pure-JS and used by main, add to `BUNDLE_INTO_MAIN` in `electron.vite.config.ts`.

## Special Directories

**`out/`** — Built outputs from `electron-vite build`. Main → `out/main/`, preload → `out/preload/`, renderer → `out/renderer/`. Generated. Not committed.

**`dist/`** — `electron-builder` packaging output (DMG/MAS, EXE, AppImage). Generated. Not committed.

**`e2e/`** — Playwright specs (separate `playwright.config.ts` and `playwright.sharing.config.ts`). Sharing E2E uses a fake RTC adapter from `src/renderer/src/testing/fakeRtcAdapter.ts`.

**`resources/`** — Icons + electron-builder assets.

**`build/`** — Per-platform packaging assets (entitlements, info.plist, etc.).

**`scripts/`** — `ensure-native-abi.cjs`, `clean-src-artifacts.cjs`, `ensure-sharp-vendor.cjs`, `mark-native-abi.cjs`. Build/dev helpers.

**`logs/`** — Runtime logs. Generated.

**`.claude/`** — Claude Code settings.

**`docs/`** — Internal docs.

**`<userData>/`** (runtime, OS-managed):
- macOS: `~/Library/Application Support/rishi-electron/`
- Windows: `%APPDATA%/rishi-electron/`
- Linux: `~/.config/rishi-electron/`
- Contains: `rishi.db`, `vectordb/`, `shared-reading-library/`, `session.enc`, `error-dump.json`, debug logs, TTS audio cache, copied book files.

---

*Structure analysis: 2026-06-09*
