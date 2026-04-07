---
phase: 06-on-device-rag-ai-conversations
plan: 01
subsystem: rag
tags: [sqlite-vec, epub, chunking, vector-search, jszip, expo-sqlite]

# Dependency graph
requires: []
provides:
  - TextChunk, SourceChunk, Conversation, Message type definitions
  - EPUB text extraction and sentence-boundary chunking pipeline
  - sqlite-vec vector store with KNN search capability
  - rawDb export for direct sqlite-vec operations
affects: [06-02, 06-03, 06-05]

# Tech tracking
tech-stack:
  added: [jszip, ts-jest]
  patterns: [sentence-boundary chunking with overlap, sqlite-vec vec0 virtual tables, rawDb export for extension loading]

key-files:
  created:
    - apps/mobile/types/conversation.ts
    - apps/mobile/lib/rag/chunker.ts
    - apps/mobile/lib/rag/vector-store.ts
    - apps/mobile/__tests__/chunker.test.ts
    - apps/mobile/__tests__/vector.test.ts
  modified:
    - apps/mobile/app.json
    - apps/mobile/lib/db.ts

key-decisions:
  - "JSZip for EPUB extraction: dynamic import to parse EPUB ZIP as base64"
  - "Sentence boundary splitting via /(?<=[.!?])\\s+/ regex with configurable overlap"
  - "rawDb export from db.ts for sqlite-vec loadExtensionSync and raw SQL operations"
  - "chunks table + chunk_vectors vec0 virtual table with 384-dim float embeddings"

patterns-established:
  - "TDD for RAG modules: mock expo-crypto/expo-file-system/rawDb, test pure logic"
  - "rawDb pattern: export raw expo-sqlite instance alongside Drizzle db for extension ops"

requirements-completed: [RAG-01, RAG-03]

# Metrics
duration: 7min
completed: 2026-04-06
---

# Phase 06 Plan 01: RAG Foundation Summary

**EPUB text chunking with sentence-boundary awareness and sqlite-vec vector store with KNN search for on-device book search**

## Performance

- **Duration:** 7 min
- **Started:** 2026-04-06T03:11:29Z
- **Completed:** 2026-04-06T03:18:35Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments
- RAG/conversation type definitions (TextChunk, SourceChunk, Conversation, Message) with full interface contracts
- EPUB text extraction pipeline: ZIP parsing, OPF spine reading, XHTML text extraction with chapter detection
- Sentence-boundary-aware chunking with configurable overlap (default 500 chars, 50 char overlap)
- sqlite-vec vector store: table creation, chunk+vector insertion, KNN search filtered by bookId, embedding check, cleanup
- 15 tests across 2 suites all passing

## Task Commits

Each task was committed atomically:

1. **Task 1: Create RAG/conversation types and configure sqlite-vec** - `815722d` (feat)
2. **Task 2: Implement EPUB text extraction and chunking** - `86857ad` (test/RED), `9693c29` (feat/GREEN)
3. **Task 3: Implement sqlite-vec vector store with KNN search** - `d71536f` (test/RED), `4208d5d` (feat/GREEN)

_Note: TDD tasks have two commits each (test then feat)_

## Files Created/Modified
- `apps/mobile/types/conversation.ts` - TextChunk, SourceChunk, Conversation, Message interfaces
- `apps/mobile/lib/rag/chunker.ts` - extractEpubText, chunkText, getChunks functions
- `apps/mobile/lib/rag/vector-store.ts` - initVectorExtension, ensureChunkTables, insertChunkWithVector, searchSimilarChunks, isBookEmbedded, deleteBookChunks
- `apps/mobile/__tests__/chunker.test.ts` - 8 tests for text chunking logic
- `apps/mobile/__tests__/vector.test.ts` - 7 tests for vector store operations
- `apps/mobile/app.json` - Added withSQLiteVecExtension config to expo-sqlite plugin
- `apps/mobile/lib/db.ts` - Exported rawDb for direct sqlite-vec operations

## Decisions Made
- JSZip for EPUB extraction: dynamic import to parse EPUB ZIP as base64
- Sentence boundary splitting via `/(?<=[.!?])\s+/` regex with configurable overlap
- rawDb export from db.ts for sqlite-vec loadExtensionSync and raw SQL operations
- chunks table + chunk_vectors vec0 virtual table with 384-dim float embeddings

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Type definitions ready for conversation CRUD (Plan 02)
- Chunking pipeline ready for embedding pipeline integration (Plan 03)
- Vector store ready for query flow (Plan 05)
- sqlite-vec extension configured and tables creation function available

## Self-Check: PASSED

- All 5 created files verified on disk
- All 5 commit hashes verified in git log

---
*Phase: 06-on-device-rag-ai-conversations*
*Completed: 2026-04-06*
