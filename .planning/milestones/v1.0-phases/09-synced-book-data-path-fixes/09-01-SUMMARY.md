---
phase: 09-synced-book-data-path-fixes
plan: 01
subsystem: rag
tags: [embedding, server-fallback, r2-download, react-native, chat]

# Dependency graph
requires:
  - phase: 06-on-device-rag-ai-conversations
    provides: RAG pipeline, embedder, server-fallback, vector-store, chat screen
  - phase: 04-cloud-sync-engine
    provides: getBookForReading async book loader with R2 download
provides:
  - embedBatchWithFallback helper in pipeline.ts (on-device first, server fallback)
  - Server-side query embedding fallback in useRAGQuery.ts
  - Async book loading in chat screen via getBookForReading
  - Non-blocking ModelDownloadCard in chat UI
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "embedBatchWithFallback: try on-device embedBatch, catch and fall back to embedTextsOnServer"
    - "Query embedding fallback: isEmbeddingReady guard with try/catch around embedSingle, server fallback"

key-files:
  created: []
  modified:
    - apps/mobile/lib/rag/pipeline.ts
    - apps/mobile/hooks/useRAGQuery.ts
    - apps/mobile/app/chat/[bookId].tsx
    - apps/mobile/__tests__/rag-pipeline.test.ts

key-decisions:
  - "embedBatchWithFallback as internal helper (not exported) keeps API surface unchanged"
  - "ModelDownloadCard moved to ListFooterComponent banner instead of blocking entire chat UI"

patterns-established:
  - "Server fallback pattern: check isEmbeddingReady, try on-device, catch and fall back to server"

requirements-completed: [RAG-08]

# Metrics
duration: 4min
completed: 2026-04-06
---

# Phase 09 Plan 01: Synced Book Data Path Fixes Summary

**Server fallback wired into RAG pipeline and chat screen uses async getBookForReading for synced books with non-blocking model download UI**

## Performance

- **Duration:** 4 min
- **Started:** 2026-04-06T15:13:26Z
- **Completed:** 2026-04-06T15:17:28Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- pipeline.ts now falls back to server-side embedding when on-device model unavailable or fails at runtime
- useRAGQuery.ts embeds queries via server when on-device model not ready, removing the hard throw
- Chat screen loads synced books via async getBookForReading (triggers R2 download)
- Chat input enabled once embedding complete regardless of model source
- ModelDownloadCard shown as non-blocking banner alongside chat, not as a gate

## Task Commits

Each task was committed atomically:

1. **Task 1: Wire server fallback into pipeline.ts and useRAGQuery.ts (TDD RED)** - `95a75ab` (test)
2. **Task 1: Wire server fallback into pipeline.ts and useRAGQuery.ts (TDD GREEN)** - `e475d1d` (feat)
3. **Task 2: Fix chat screen to use getBookForReading and remove model-required gate** - `819c168` (fix)

## Files Created/Modified
- `apps/mobile/lib/rag/pipeline.ts` - Added embedBatchWithFallback helper, replaced embedBatch call
- `apps/mobile/hooks/useRAGQuery.ts` - Added server fallback for query embedding, removed throw guard
- `apps/mobile/app/chat/[bookId].tsx` - Switched to getBookForReading, removed modelReady gates, non-blocking ModelDownloadCard
- `apps/mobile/__tests__/rag-pipeline.test.ts` - Added 3 new fallback tests, updated existing tests with isEmbeddingReady mock

## Decisions Made
- embedBatchWithFallback kept as internal (non-exported) helper to avoid expanding the module API surface
- ModelDownloadCard converted from a blocking gate that replaces the entire chat UI to a non-blocking banner in ListFooterComponent

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Synced books now work correctly in chat with on-demand R2 download and server-side embedding fallback
- No further phases depend on this gap closure

---
*Phase: 09-synced-book-data-path-fixes*
*Completed: 2026-04-06*
