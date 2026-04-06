---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: unknown
stopped_at: Completed 10-02-PLAN.md
last_updated: "2026-04-06T19:05:39.292Z"
progress:
  total_phases: 11
  completed_phases: 10
  total_plans: 28
  completed_plans: 28
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-05)

**Core value:** Users can read their books and interact with AI on their phone with the same experience they get on desktop, with everything synced between devices.
**Current focus:** Phase 10 — desktop-feature-parity

## Current Position

Phase: 10 (desktop-feature-parity) — EXECUTING
Plan: 3 of 3

## Performance Metrics

**Velocity:**

- Total plans completed: 0
- Average duration: -
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**

- Last 5 plans: -
- Trend: -

*Updated after each plan completion*
| Phase 01 P01 | 5min | 2 tasks | 7 files |
| Phase 01 P02 | 2min | 4 tasks | 5 files |
| Phase 02 P01 | 3min | 3 tasks | 7 files |
| Phase 02 P02 | 6min | 2 tasks | 5 files |
| Phase 02 P03 | 3min | 3 tasks | 7 files |
| Phase 03 P01 | 2min | 2 tasks | 7 files |
| Phase 03 P02 | 3min | 2 tasks | 4 files |
| Phase 04 P01 | 15min | 3 tasks | 16 files |
| Phase 04 P02 | 4min | 2 tasks | 11 files |
| Phase 04 P03 | 3min | 2 tasks | 5 files |
| Phase 05 P01 | 3min | 2 tasks | 5 files |
| Phase 05 P03 | 2min | 2 tasks | 2 files |
| Phase 05 P02 | 4min | 2 tasks | 6 files |
| Phase 05 P04 | 1min | 2 tasks | 2 files |
| Phase 06 P04 | 3min | 1 tasks | 4 files |
| Phase 06 P01 | 7min | 3 tasks | 7 files |
| Phase 06 P02 | 11min | 2 tasks | 8 files |
| Phase 06 P03 | 3min | 2 tasks | 7 files |
| Phase 06 P05 | 8min | 3 tasks | 13 files |
| Phase 07 P01 | 11min | 2 tasks | 9 files |
| Phase 07 P02 | 12min | 2 tasks | 8 files |
| Phase 08 P01 | 8min | 2 tasks | 7 files |
| Phase 08 P02 | 5min | 2 tasks | 7 files |
| Phase 08 P03 | 8min | 3 tasks | 7 files |
| Phase 09 P01 | 4min | 2 tasks | 4 files |
| Phase 10 P01 | 4min | 2 tasks | 8 files |
| Phase 10 P03 | 35min | 3 tasks | 8 files |
| Phase 10 P02 | 45min | 3 tasks | 11 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Init]: On-device embeddings primary, server fallback for bulk (react-native-executorch + all-MiniLM-L6-v2)
- [Init]: Build on existing Expo scaffold at apps/mobile/ (Expo 54, NativeWind, New Architecture)
- [Init]: D1 + R2 sync backend with LWW conflict resolution, expo-sqlite + Drizzle on mobile
- [Init]: Desktop sync integration in scope as late phase (Phase 8) -- mobile standalone first
- [Phase 01]: Used Slot instead of Stack in root layout for route group navigation
- [Phase 01]: Custom sign-in UI with useSignIn/useOAuth hooks for NativeWind styling control
- [Phase 01]: initApiClient pattern: pass getToken from useAuth hook to avoid hooks-in-non-component code
- [Phase 01]: 5-minute expiry buffer on Worker JWT to proactively refresh before 401
- [Phase 02]: expo-sqlite openDatabaseSync singleton pattern for synchronous DB access
- [Phase 02]: Books stored at documentDirectory/books/<uuid>/book.epub for persistence
- [Phase 02]: Title from filename, author defaults to Unknown, cover extraction deferred to reader open
- [Phase 02]: Added book.fill and plus icon mappings to Android MaterialIcons fallback
- [Phase 02]: ReaderProvider wraps Reader content separately -- useReader hook requires provider context above Reader
- [Phase 02]: onSingleTap prop on Reader for toolbar toggle instead of TouchableWithoutFeedback wrapper
- [Phase 02]: Settings table with key-value SQLite storage for reader preferences
- [Phase 03]: Custom PDF toolbar instead of reusing EPUB ReaderToolbar (PDF has no themes/TOC)
- [Phase 03]: Page navigation via controlled page prop state (react-native-pdf has no imperative setPage)
- [Phase 03]: Alert-based format chooser for import (simple, no extra UI needed)
- [Phase 03]: Trash icon button instead of swipe-to-delete for simplicity
- [Phase 03]: Conditional cover placeholder colors (red-100 for PDF, gray-200 for EPUB)
- [Phase 04]: Shared schema in @rishi/shared workspace package for D1 and mobile SQLite parity
- [Phase 04]: userId column on books table for server-side multi-user scoping (null on mobile)
- [Phase 04]: filePath/coverPath stripped from D1 upserts and pull responses to prevent path contamination
- [Phase 04]: aws4fetch with signQuery:true for presigned URLs (no Content-Type in signed headers)
- [Phase 04]: LWW conflict resolution based on updatedAt timestamp comparison
- [Phase 04]: Global file dedup by fileHash across all users
- [Phase 04]: ALTER TABLE migrations with try/catch for additive sync columns on mobile
- [Phase 04]: Back-fill existing books as isDirty=true for first sync push
- [Phase 04]: Soft delete (isDeleted flag) instead of hard DELETE for sync propagation
- [Phase 04]: Pull never overwrites local filePath/coverPath (path contamination prevention)
- [Phase 04]: isSyncing mutex prevents concurrent push/pull cycles
- [Phase 04]: Fire-and-forget upload: import returns immediately, hash+upload runs in background
- [Phase 04]: getBookForReading: async wrapper with on-demand R2 download for remote books
- [Phase 05]: Used expo-crypto randomUUID for highlight ID generation (consistent with file-sync.ts)
- [Phase 05]: Separate upsertedBookIds/upsertedHighlightIds arrays for syncVersion clarity
- [Phase 05]: Conflict type detection via cfiRange field presence (highlights have cfiRange, books do not)
- [Phase 05]: Global syncVersion computed as Math.max across books and highlights tables
- [Phase 05]: menuItems action returns boolean per @epubjs-react-native API (not string action names)
- [Phase 05]: removeAnnotationByCfi for CFI-based removal (removeAnnotation requires full Annotation object)
- [Phase 05]: AnnotationPopover positioned at screen center-top since onPressAnnotation lacks pixel coords
- [Phase 05]: Removed onSelected prop entirely -- menuItems already cover all highlight creation paths
- [Phase 05]: Pull-side LWW guard uses strict less-than so equal timestamps still apply remote syncVersion updates
- [Phase 06]: Jest test infrastructure added to mobile app for TDD (jest, ts-jest, @types/jest)
- [Phase 06]: JSZip for EPUB extraction: dynamic import to parse EPUB ZIP as base64
- [Phase 06]: rawDb export from db.ts for sqlite-vec loadExtensionSync and raw SQL operations
- [Phase 06]: chunks table + chunk_vectors vec0 virtual table with 384-dim float embeddings
- [Phase 06]: Conversation conflict type detection via title+bookId fields (not filePath) to distinguish from books
- [Phase 06]: Messages use append-only merge: never updated during sync, only new ones inserted
- [Phase 06]: Pull messages via user conversation IDs (messages lack userId column)
- [Phase 06]: Jest+ts-jest with schema/drizzle-orm mocks for mobile unit testing
- [Phase 06]: Singleton forward function pattern: useEmbeddingModel hook registers forward fn via setEmbeddingForward so pipeline can embed outside React context
- [Phase 06]: Batch size 10 with 50ms delay between batches to manage mobile memory pressure
- [Phase 06]: RAG system prompt matches desktop version for consistent AI behavior across platforms
- [Phase 06]: Conversation history limited to last 6 messages in LLM context to manage token budget
- [Phase 06]: message.fill icon with chat-bubble Android MaterialIcons fallback for Chat tab
- [Phase 07]: Used createAudioPlayer (non-React API) for TTSPlayer class since it runs outside React context
- [Phase 07]: Base64 mp3 caching to FileSystem.cacheDirectory with prefetch-next-2 strategy
- [Phase 07]: Disabled toolbar auto-hide when TTS active so user retains access to stop button
- [Phase 07]: apiClient Content-Type default before spread: allows binary upload override without breaking JSON callers
- [Phase 07]: externalText prop on ChatInput for transcript injection from parent (voice transcription)
- [Phase 07]: Base64->Uint8Array conversion in useVoiceInput: expo-file-system reads base64, Worker expects raw binary
- [Phase 08]: Migration tests in db.rs module (not separate file) for access to embedded MIGRATIONS constant
- [Phase 08]: Rust UUID backfill as safety net after SQL randomblob-based backfill in migration
- [Phase 08]: Removed Kysely createTable calls -- Diesel migrations now manage all schema
- [Phase 08]: DOM lib added to shared tsconfig for fetch/console types (both consumers have DOM)
- [Phase 08]: vi.hoisted pattern for Kysely mock functions in vitest (factory hoisting requirement)
- [Phase 08]: Web Crypto API crypto.subtle.digest for SHA-256 file hashing (no extra dependency)
- [Phase 08]: Highlight persistence keyed by book sync_id (UUID) for cross-device sync compatibility
- [Phase 08]: SyncStatusIndicator wired into __root.tsx sidebar footer (TanStack Router layout pattern)
- [Phase 09]: embedBatchWithFallback as internal helper: try on-device embedBatch, catch and fall back to embedTextsOnServer
- [Phase 09]: ModelDownloadCard as non-blocking ListFooterComponent banner instead of gate that hides entire chat UI
- [Phase 10]: vi.hoisted Kysely mock chain pattern reused for highlight-storage tests
- [Phase 10]: embedWithFallback catches on-device errors and maps server response to EmbedResult format
- [Phase 10]: triggerSyncOnWrite uses setTimeout/clearTimeout debounce at 2000ms (zero external dependencies)
- [Phase 10]: MediaRecorder MIME type: check audio/webm;codecs=opus support first, fall back to audio/webm
- [Phase 10]: Source chunks retrieved by matching context text against chunk_data.data column (exact match)
- [Phase 10]: rendition?.display(pageNumber) used for source chip navigation (spine index)
- [Phase 10]: Conversation auto-created on first use per book (no explicit New Chat required)
- [Phase 10]: Selection popover shows color picker instead of auto-creating yellow highlight on text select
- [Phase 10]: ReaderSettings persisted via @tauri-apps/plugin-store under 'reader-settings' key for cross-session font state

### Roadmap Evolution

- Phase 10 added: Desktop Feature Parity — highlights UI, reader settings, voice input, embedding fallback, source refs, write-triggered sync
- Phase 11 added: Mobile Feature Parity — realtime voice chat, AI guardrails, sync status indicator, Sentry error tracking

### Pending Todos

None yet.

### Blockers/Concerns

- Desktop sync scope: PROJECT.md originally listed desktop changes as out of scope, but bidirectional sync (Phase 8) requires desktop schema migration and sync engine. Decision needed before Phase 4 planning.
- No Expo Go: react-native-pdf and react-native-executorch require native modules. Development uses custom dev client only (set up in Phase 1).
- Embedding model delivery: ~80MB model download on first use needs graceful UX. Decision: download-on-first-use with progress indicator.

## Session Continuity

Last session: 2026-04-06T19:05:39.290Z
Stopped at: Completed 10-02-PLAN.md
Resume file: None
