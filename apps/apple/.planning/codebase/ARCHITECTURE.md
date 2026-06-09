# Architecture

**Analysis Date:** 2026-06-09

**Target codebase:** `apps/rishi-electron` (the existing Electron desktop reader). This document describes how that app is structured so an iOS/SwiftUI port can mirror the same modules, IPC-equivalent boundaries, and data flows.

## Pattern Overview

**Overall:** Three-process Electron application built on **electron-vite** with a strict main / preload / renderer split.

- **Main process** (`src/main/`): Node.js. Owns native resources (SQLite, HNSW vector index, file system, OS dialogs, OAuth/PKCE, deep-link protocol, BrowserWindow lifecycle, application menu, auto-updater, deep-link / sharing).
- **Preload script** (`src/preload/index.ts`): Privileged bridge. Exposes a typed surface on `window.electron` and `window.api.auth` via `contextBridge`. Single source of truth for the IPC contract lives in `src/preload/ipc-contract.ts`.
- **Renderer** (`src/renderer/src/`): React 19 SPA with **TanStack Router** (hash history) + **TanStack Query** + **Zustand** stores + **XState** state machines. All UI, format parsing for in-memory data, TTS/voice chat orchestration, sync coordination, sharing P2P logic lives here.

**Key Characteristics:**
- **Multi-window**: one library window, one settings window, and N book-reader windows. Each `BrowserWindow` is identified by `--window-identity=library|settings|book:<id>` passed via `additionalArguments` in `src/main/windows/createBrowserWindow.ts`. The renderer reads this flag in `src/preload/windowIdentity.ts` and the root route enforces it.
- **Typed IPC contract**: `src/preload/ipc-contract.ts` declares `IpcContract` mapping channel name → `{ args, returns }`. Both `invoke()` (renderer side) and `handle()` (main side) are generic over the contract — channel typos and arg-shape mismatches are compile errors.
- **Strict security boundary**: `contextIsolation: true`, `nodeIntegration: false`, `sandbox: false`. Renderer never touches `fs`, `electron`, or `better-sqlite3` directly — every privileged action funnels through IPC.
- **Local-first, sync-second**: SQLite (`rishi.db`) is the source of truth. A background sync engine pushes dirty rows + pulls remote rows from a Cloudflare Worker. The renderer treats sync as optional and works fully offline.
- **Service-port pattern in the renderer**: each subsystem (sync, tts, book-import, rag, voice-chat) is a `createXService({ ipc, fetch, ... })` factory that accepts injected ports. Tests substitute fakes; production wires `window.electron.*`. See `src/renderer/src/services/index.ts` for the singleton wiring.

## Layers

**Main process — Native + persistence layer**
- Location: `src/main/`
- Purpose: All Node-only capabilities and singletons.
- Contains: SQLite open + migrations, HNSW vector index, IPC handler registrations, OAuth/PKCE flow, deep-link protocol handler, window/menu management, file format parsing (EPUB/MOBI/AZW3), filesystem helpers, auto-updater, Sentry, P2P sharing persistence.
- Depends on: Electron APIs, `better-sqlite3`, `drizzle-orm` (schema only — raw queries used in practice), `hnswlib-node`, `jszip`, `@xenova/transformers` (for embeddings).
- Used by: preload (handler registrations) → renderer via IPC.

**Preload — Typed bridge**
- Location: `src/preload/`
- Purpose: Defines `IpcContract` and projects it into `window.electron` (flat methods) + `window.api.auth` (auth namespace). Parses `--window-identity` argv and exposes `windowIdentity` to the renderer.
- Files: `index.ts` (binds methods), `ipc-contract.ts` (the contract + `invoke`/`handle` helpers), `types.ts` (renderer-facing `ElectronAPI`/`Api` types, derived from the contract via `ChannelToMethod`), `windowIdentity.ts` (argv parser).
- Contains no business logic — it's purely shape declaration + thin wrappers.

**Renderer — UI + orchestration**
- Location: `src/renderer/src/`
- Sub-layers:
  - **`routes/`**: TanStack Router file-based routes (`__root.tsx`, `index.lazy.tsx`, `books.$id.lazy.tsx`, `settings/account.tsx`). Hash history (`createHashHistory()`).
  - **`components/`**: React UI organised by domain folder (`library/`, `reader/`, `epub/`, `pdf/`, `azw3/`, `chat/`, `auth/`, `tts/`, `sharing/`, `highlights/`, `bookmarks/`, `tutorial/`, `ui/` for primitives).
  - **`stores/`**: Zustand stores — single source of truth for UI/runtime state (`authStore`, `epubStore`, `pdfStore`, `playerStore`, `chatStore`, `indexingStore`, `prefsStore`, `selectionStore`, `tutorialStore`, `navStore`).
  - **`machines/`**: XState state machines for complex flows (`playerMachine` for TTS playback, `pdfReaderMachine`, `navMachine`, `sessionMachine`, `connectivityMachine`).
  - **`actors/`**: XState actors invoked by machines (`audioActor`, `epubViewActor`, `pdfViewActor`, `ttsFetchActor`, `viewActor`, `sharing/`).
  - **`services/`**: Pure-business-logic services with port-style dependency injection (`book-import/`, `sync/`, `rag/`, `tts/`, `connectivity/`, `indexing/`, `reader-cache/`). Wired in `services/index.ts`.
  - **`modules/`**: Lower-level helpers that don't fit "service" shape (`auth.ts`, `books.ts`, `embed-fallback.ts`, `file-sync.ts`, `pdf-locator.ts`, `updater.ts`, `epub-page-tracker.ts`, `pageCapture/`, `resolve-live-selection/`, `read-aloud-from/`).
  - **`hooks/`**: React hooks (`useHydrateAuth`, `useMenuCommands`, `useFileOpenHandler`, `usePlayerMachine`, `useSessionMachine`, `usePostImportSync`, `useChat`, `useStartupUpdateCheck`, etc.).
  - **`lib/`**: Renderer-side API client (`api.ts` — wraps `window.electron` IPC + remote worker fetches), helpers, types.
  - **`sharing/`**: Renderer glue for shared-reading sessions (`epubSyncBridge.ts`, `pdfSyncBridge.ts`, `sentryScope.ts`).

## Data Flow

**Authentication (magic-link / Google OAuth)**

1. User taps "Sign in" → renderer calls `window.api.auth.startMagicLink(email)` or `startGoogle()`.
2. Main `auth-service.ts` (`src/main/auth/auth-service.ts`) generates PKCE pair (`pkce.ts`), POSTs `/desktop/start` to `https://api.fidexa.org`.
3. For magic-link: worker emails a link to the web app. For Google: main calls `shell.openExternal()` with the worker-returned URL — sign-in happens in the system browser (not in-app).
4. Main polls `/desktop/poll` every 2s with `code_verifier`. On success it receives a session token, encrypts it via `safeStorage`, writes atomically to `userData/session.enc` (`src/main/auth/session-store.ts`).
5. Main fetches `/user/me`, broadcasts the user object on `'session-changed'` to every `BrowserWindow.webContents`.
6. Renderer's `useHydrateAuth` hook (`src/renderer/src/hooks/useHydrateAuth.tsx`) listens via `window.api.auth.onSessionChange(cb)` and updates `authStore`.
7. Deep-link variant: `rishi://` protocol routed by `src/main/sharing/deepLink.ts`. Google OAuth is **blocked on MAS builds** (`process.mas` check) per App Store rules.

**Library load → reader**

1. Library window mounts → `__root.tsx` runs `useQuery({ queryKey: ['books'] })` → `getBooks()` in `lib/api.ts` → `window.electron.getBooks()` → IPC `books:getAll` → `src/main/ipc/books.ts` → `getAllBooks()` in `src/main/database/queries.ts` → SQLite.
2. Covers are loaded lazily (`books:getCover`) by `components/library/coverCache.ts`.
3. Click a book → renderer calls `window.electron.openBook(bookId)` → IPC `window:openBook` → main `WindowManager.openBook` (`src/main/windows/windowManager.ts`) creates a new `BrowserWindow` with `--window-identity=book:<id>` and loads `#/books/<id>`.
4. Book window root route resolves the route, fetches metadata (`books:get`), and dispatches to `<PdfView>` / `<EpubView>` / `<Azw3View>` based on `book.kind`.

**Reading + position persistence**

1. EPUB: `EpubView.tsx` boots `epubjs` against the `local-file://` protocol (registered in `src/main/index.ts` → `registerLocalFileProtocol`). Page renders inside `about:srcdoc` iframes (requires `webSecurity: false` on book windows only).
2. PDF: `PdfView.tsx` uses `react-pdf` with a custom worker.
3. As the user navigates, current CFI / page number is debounced and persisted via `window.electron.updateBookLocation(bookId, location)` → IPC `books:updateLocation` → SQLite update. Book windows intercept `close` and call `window.__rishi.flushPendingSaves()` before destroy (`src/main/windows/createBrowserWindow.ts`).

**Indexing + RAG (semantic search)**

1. On import, `services/book-import/indexer.ts` walks pages, computes embeddings via `@xenova/transformers` (renderer-side via `modules/embed-fallback.ts`, with a main-process fallback through IPC `vectors:embed`).
2. Vectors + page-id pairs are written via `vectors:save` → `src/main/vectordb/index.ts` → HNSW persisted to `<userData>/vectordb/<bookId>-vectordb.hnsw` with atomic tmp+rename.
3. Page text is stored in SQLite `chunk_data` table for full-text fallback.
4. `services/rag/service.ts` exposes `searchSemantic` (HNSW nearest-neighbour → `getTextFromVectorId`) and `searchText` (SQLite LIKE/FTS).

**Chat / Voice AI**

1. Text chat: `components/chat/ChatPanel.tsx` + `hooks/useChat.ts` + `stores/chatStore.ts`. Calls remote worker for completions; uses RAG service to attach `sourceChunks` per message; persists conversations + messages in SQLite (`conversations`, `messages` tables) via dedicated IPC channels.
2. Voice chat: `getVoiceChatService()` in `services/index.ts` wires the shared `@rishi/shared/voice-chat` package against `OpenAIRealtimeWebRTC`. Uses WebRTC for the audio path, server VAD via OpenAI, local VAD via WebAudio. Realtime client secret minted by the worker (`getRealtimeClientSecret` in `lib/api.ts`).
3. TTS: `services/tts` (re-exports `@rishi/shared/tts`). Audio cached on disk in `userData` (managed via `fs:linkOrCopyFile`, `fs:getCacheFileStats`). Playback orchestrated by `playerMachine` (XState) which invokes `audioActor`, `ttsFetchActor`, and one of `epubViewActor` / `pdfViewActor` for scroll-to-paragraph behaviour.

**Sync (push / pull dirty rows)**

1. `getSyncService()` (`services/sync/service.ts`) is started in `__root.tsx` on mount.
2. Loop: connectivity-aware debounce (`createDebouncer`) → gather dirty rows (`syncGetDirtyBooks`, `…Highlights`, `…Conversations`, `…Messages`) → POST to Cloudflare Worker (`WORKER_URL` from `config/worker-url.ts`) with `Authorization: Bearer <token>` from `getAuthToken()`.
3. Worker returns conflicts + new server rows; service applies via `syncApplyBookConflict`, `syncUpsertBook`, etc., updates `sync_meta.lastSyncVersion`.
4. Books also sync their binary file separately: `modules/file-sync.ts` hashes the file (`hashBookFile`), uploads to R2 via worker (`uploadBookFile`), and writes `file_hash` + `file_r2_key` back via `booksUpdateFileHash`.

**Shared reading (P2P)**

1. Host taps Share → `sharing/getSigningJwt` IPC → main signs a session-creation token.
2. Renderer connects to sharing WebSocket (`config.production.audio_worker_url` and friends in `src/renderer/src/config.json`), negotiates WebRTC via `iceServers` from `sharing:getConfig`.
3. P2P file transfer pipes book bytes through the data channel. Receiver calls `sharing:saveTransferredBook` → `src/main/sharing/libraryWrite.ts` writes to `<userData>/shared-reading-library/<contentHash>.<ext>` and inserts a `books` row with `source='shared-session'`, `received_from_user_id`, `received_at`.
4. Reconnect tokens persisted via `sharing:writeReconnect` to survive host restarts (`reconnectStore.ts`).
5. Deep links `rishi://sharing/join?t=<token>` route through `src/main/sharing/deepLink.ts` → `'sharing:deepLinkReceived'` event to renderer.

**State Management:**
- **Zustand** for UI state (per-store in `src/renderer/src/stores/`), persisted selectively via `localStorage` (e.g., `prefsStore`, `tutorialStore`, welcome flags in `authStore`).
- **TanStack Query** for server/IPC-backed read state (book list, book metadata).
- **XState** for finite-state flows (`playerMachine`, `pdfReaderMachine`, `sessionMachine`, `navMachine`, `connectivityMachine`).
- **TanStack Router** for navigation; route params drive book selection (`/books/$id`).

## Key Abstractions

**`IpcContract`** (`src/preload/ipc-contract.ts`)
- Purpose: Single typed map of every channel → `{ args, returns }`. Adding a channel here flows types into both `invoke()` callers and `handle()` registrations.
- Pattern: `'namespace:action': { args: [...]; returns: ... }`.

**`WindowIdentity`** (`src/main/windows/windowManager.ts`)
- Purpose: Discriminated union `{ kind: 'library' | 'book' | 'settings'; bookId? }` that drives window lifecycle, route enforcement, menu context, and IPC routing.
- Mirror in iOS: distinguish your library scene vs reader scene vs settings scene; the bookId becomes the binding ID for a reader view.

**`MenuContext`** (`src/main/menu/commands.ts`)
- Purpose: Per-window structured state used by the native menu builder (theme, kind, format, tocOpen, thumbsOpen, dualPage, recentBooks, openBookTitles, bookmarks).
- On iOS: maps to per-scene state that drives `Menu`, `Commands`, and keyboard shortcuts.

**Service factories** (`src/renderer/src/services/*/service.ts`)
- Purpose: All major renderer subsystems use `createXService({ deps })` returning an object with action methods + emitters. Deps include `ipc`, `fetch`, `connectivity`, `clock`, `config`.
- Mirror in Swift: each service is a class with explicit init dependencies — easy to substitute in tests, easy to port.

**Reader format adapters**
- EPUB: `components/epub/EpubView.tsx` + `modules/epubwrapper.ts` (wraps `epubjs`) + `modules/epub-page-tracker.ts`.
- PDF: `components/pdf/PdfView.tsx` + `react-pdf` + `modules/pdf-locator.ts`.
- AZW3 / MOBI: `components/azw3/` + `foliate-js` (single `Azw3View` handles both via auto-detection).
- Pattern: each format owns a viewer component, a position model (CFI vs page+offset), and an actor (`epubViewActor`, `pdfViewActor`) used by `playerMachine` to scroll/highlight during TTS.

## Entry Points

**Main process entry:** `src/main/index.ts` (`apps/rishi-electron/out/main/index.js` after build).
- Registers OS-level handlers (`open-file` on macOS, single-instance lock, `second-instance` argv routing, `rishi://` protocol).
- Initialises Sentry, database, vector store, IPC handlers, auth IPC.
- Creates `WindowManager` + `MenuInstaller`, opens library window.

**Preload script:** `src/main/index.ts` resolves it as `join(__dirname, '../preload/index.js')` (built from `src/preload/index.ts`). Bound to every `BrowserWindow` via `webPreferences.preload`.

**Renderer root:** `src/renderer/index.html` → `src/renderer/src/main.tsx` → `RouterProvider` mounting the file-based route tree generated at `src/renderer/src/routeTree.gen.ts` (root: `routes/__root.tsx`).

**Deep-link handler:** `src/main/sharing/deepLink.ts` (`rishi://sharing/join?t=...`). Registered after the main window exists; buffers tokens received pre-`did-finish-load`.

**File-open handler:** `app.on('open-file', ...)` in `src/main/index.ts` (macOS); argv parsing on second-instance for Windows/Linux. Filtered to `.epub/.pdf/.mobi/.azw3` and pushed to the renderer via the `'open-files'` channel; consumed by `hooks/useFileOpenHandler.ts`.

**Custom protocol:** `local-file://` registered in `registerLocalFileProtocol()` (main) so the renderer can `<img src="local-file:///abs/path/cover.jpg">` and EPUB/PDF readers can stream local files without disabling web security globally.

## Error Handling

**Strategy:** Main-side handlers wrap all DB / fs / parse operations in try/catch + `errorMessage()` (`src/main/utils/errors.ts`) and rethrow with descriptive messages. Renderer surfaces failures via `toast` (sonner), Sentry capture, and an error-dump file (`src/main/ipc/debug.ts` → `error-dump.json` in `userData`).

**Patterns:**
- **Atomic writes:** every persistence path that could corrupt on crash uses `atomicWriteFile` (`src/main/utils/atomicWrite.ts`) — tmp file + rename. Used by `session-store`, vector index, auth state.
- **Crash-loop guard:** `handleRenderProcessGone` in `src/main/index.ts` tracks recent crashes per window and shows a "persistent crash" dialog instead of looping reload.
- **IPC-level zod validation:** sharing handlers validate payloads with zod schemas (`src/main/sharing/sharing.schemas.ts`) before dispatching — main-side defence against compromised renderer.
- **ErrorBoundary** wraps `<Outlet />` in the root route to contain renderer exceptions.

## Cross-Cutting Concerns

**Logging:**
- Main: `console.log` + Sentry (`src/main/utils/sentry.ts`, initialised before anything else).
- Renderer: Sentry via `src/renderer/src/utils/sentry.ts`, plus append-only newline-JSON debug log via IPC `debug:appendLog` for fine-grained timeline tracing.

**Validation:** zod (`src/main/sharing/sharing.schemas.ts`, `src/main/ipc/sync.schemas.ts`) at IPC boundaries that receive remote/untrusted shapes.

**Authentication:**
- Session token stored encrypted at `<userData>/session.enc` via Electron `safeStorage`.
- Outbound to worker: `Authorization: Bearer <token>` (NEVER cookies — Chromium strips them in fetch from renderer).
- Dev override: `X-Dev-Bypass: <secret>` header when `getDevBypassSecret()` returns a value (only in dev builds).
- `process.mas` gates Google OAuth (disallowed on Mac App Store builds).

**Theming:** Tailwind v4 with a `dark` class toggled on `<html>`. Theme published to the main process via `menu:setContext` so the native menu label ("Switch to Dark Mode" vs "Switch to Light Mode") tracks renderer state.

## Service Boundaries an iOS Port Needs to Mirror

Each of the following maps to a Swift class/actor in a SwiftUI app. The IPC channel names give you the surface; the implementation file shows the behaviour.

| Subsystem | Electron implementation | iOS equivalent |
| --- | --- | --- |
| **Auth** (PKCE, magic-link, OAuth, session storage) | `src/main/auth/auth-service.ts`, `pkce.ts`, `session-store.ts` | `AuthService` + Keychain |
| **Local DB** (books, chunks, highlights, bookmarks, conversations, messages, sync_meta) | `src/main/database/schema.ts`, `queries.ts`, `migrations.ts` | GRDB or SQLite.swift with mirror schema |
| **Vector store** (HNSW, 384-dim cosine) | `src/main/vectordb/index.ts`, `embeddings.ts` | `NaturalLanguage` embeddings or USearch; persist per-book index |
| **Format parsing** (EPUB metadata, PDF cover/metadata, MOBI/AZW3) | `src/main/ipc/formats.ts` | Native EPUB parser + PDFKit + foliate equivalent |
| **File system + book copy/import** | `src/main/ipc/fs.ts`, renderer `modules/file-sync.ts`, `modules/books.ts` | `FileManager` + URL-bookmark security scoping |
| **Scanner** (background folder scan) | `src/main/ipc/scanner.ts` | Optional on iOS; use document picker instead |
| **Window/menu/identity routing** | `src/main/windows/windowManager.ts`, `menu/menuBuilder.ts`, `preload/windowIdentity.ts` | Scene-based navigation, `Commands` builder |
| **Deep links** (`rishi://`, file open) | `src/main/sharing/deepLink.ts`, `app.on('open-file')` | `onOpenURL`, `Universal Links`, `UIDocumentInteraction` |
| **Sync engine** (push dirty, pull conflicts, R2 file upload) | `services/sync/service.ts`, `modules/file-sync.ts`, `@rishi/shared/sync-engine` | Background URLSession + `BackgroundTasks` |
| **Sharing P2P** (WebRTC, JWT auth, reconnect tokens) | `actors/sharing/*`, `src/main/sharing/*`, `@rishi/sharing-protocol` | WebRTC iOS (Google) + signing JWT via worker |
| **Reader engine** (EPUB/PDF/AZW3 viewers + scroll/highlight/TOC) | `components/epub/`, `components/pdf/`, `components/azw3/`, `components/react-reader/` | Native EPUB renderer (or `WKWebView`) + `PDFKit` |
| **RAG** (vector + text search, source attribution) | `services/rag/service.ts` | Same shape, native vector index |
| **Voice chat** (OpenAI Realtime + WebRTC + VAD) | `getVoiceChatService()` via `@rishi/shared/voice-chat` | OpenAI Realtime via WebRTC; iOS `AVAudioEngine` for VAD |
| **TTS** (audio cache, paragraph cue, prefetch) | `services/tts/`, `playerMachine`, `audioActor` | `AVAudioPlayer` + on-disk cache |
| **Chat** (conversations, messages, sourceChunks, billing gate) | `components/chat/`, `stores/chatStore.ts`, `hooks/useChat.ts` | `ChatStore` + URLSession streaming |
| **Connectivity** (online/offline, push events to sync/TTS) | `services/connectivity/` | `NWPathMonitor` |
| **Updater** (electron-updater) | `src/main/ipc/updater.ts`, `modules/updater.ts` | App Store; no-op or in-app update banner |
| **Billing gate / dev bypass** | `Authorization: Bearer` + `X-Dev-Bypass` headers | Same headers from `URLSession` |

The iOS app collapses the main/preload/renderer split into a single process. The IPC channels become method calls on native services; the renderer's stores/services map almost 1:1 onto `@StateObject` / `ObservableObject` / `Actor` types in Swift.

---

*Architecture analysis: 2026-06-09*
