# Phase 9: Synced-Book Data Path Fixes - Research

**Researched:** 2026-04-06
**Domain:** Mobile RAG pipeline / sync integration bug fixes
**Confidence:** HIGH

## Summary

This phase closes two specific gaps identified by the v1.0 milestone audit. Both are wiring bugs -- the building blocks exist but are not connected correctly.

**Gap 1 (Integration):** `apps/mobile/app/chat/[bookId].tsx` line 80 calls `getBookById(bookId)` (synchronous, returns DB row as-is) instead of `getBookForReading(bookId)` (async, triggers on-demand R2 download for synced books). When a book arrives from another device via sync, its `filePath` is empty until the file is downloaded. The chat screen never triggers the download, so `embedBook` receives an empty path, the chunker returns `[]`, no vectors are stored, and RAG queries return nothing. TTS also breaks because it needs the file to extract text.

**Gap 2 (Pipeline):** `apps/mobile/lib/rag/pipeline.ts` calls `embedBatch` from `embedder.ts` which requires the on-device ExecuTorch model. If the model is not downloaded, `embedBatch` throws `'Embedding model not ready'`. The server-side fallback (`embedTextsOnServer` in `server-fallback.ts`) exists and works in isolation but is never called as an automatic fallback. The pipeline should try on-device first and fall back to server when the model is unavailable.

**Primary recommendation:** Fix both gaps with minimal, targeted changes -- swap `getBookById` for `getBookForReading` in the chat screen, and add server fallback logic to `pipeline.ts` when `isEmbeddingReady()` returns false.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| RAG-08 | Server-side embedding fallback available for bulk book imports | Gap 2 fix: wire `embedTextsOnServer` as automatic fallback in `pipeline.ts` when on-device model is not ready. Gap 1 fix (prerequisite): ensure synced books have a valid `filePath` before embedding starts. |
</phase_requirements>

## Standard Stack

No new libraries needed. This phase exclusively modifies existing files using already-imported modules.

### Core (already in project)
| Library | Purpose | Used In |
|---------|---------|---------|
| expo-file-system | File existence checks, R2 download target | `book-storage.ts` |
| react-native-executorch | On-device embedding model | `useEmbeddingModel.ts`, `embedder.ts` |
| expo-sqlite + sqlite-vec | Vector storage | `vector-store.ts` |
| drizzle-orm | Database queries | `book-storage.ts` |

### Supporting (already in project)
| Library | Purpose | Used In |
|---------|---------|---------|
| @/lib/api (apiClient) | Authenticated HTTP to Worker | `server-fallback.ts` |
| @/lib/sync/file-sync (downloadBookFile) | R2 file download | `book-storage.ts` |

**Installation:** None required.

## Architecture Patterns

### Pattern 1: getBookForReading async download pattern
**What:** `getBookForReading(id)` checks if a local file exists. If not (synced book), it downloads from R2 via presigned URL, updates `filePath` in the DB, and returns the complete Book object.
**Where defined:** `apps/mobile/lib/book-storage.ts` lines 52-81
**Key detail:** Returns `Promise<Book | null>` -- callers must `await` it. The chat screen's `useEffect` on line 78 currently uses the synchronous `getBookById` -- it needs to become async.

```typescript
// Current (broken for synced books):
useEffect(() => {
  if (bookId) {
    const loaded = getBookById(bookId)
    setBook(loaded)
  }
}, [bookId])

// Fixed:
useEffect(() => {
  if (bookId) {
    getBookForReading(bookId).then(setBook)
  }
}, [bookId])
```

### Pattern 2: Singleton forward function (embedder.ts)
**What:** `useEmbeddingModel` hook registers a `forward` function via `setEmbeddingForward()`. Non-React code calls `embedBatch()` / `embedSingle()` which delegates to the registered function. `isEmbeddingReady()` checks if the function is registered.
**Key insight for fallback:** When `isEmbeddingReady()` returns false, the pipeline should use `embedTextsOnServer()` instead of throwing.

### Pattern 3: Server fallback embedding
**What:** `embedTextsOnServer(texts)` POSTs to Worker `/api/embed` endpoint. Returns `number[][]` (384-dim vectors, same dimensionality as on-device model).
**Key detail:** Same vector dimensions (384) as on-device all-MiniLM-L6-v2 -- vectors are interchangeable in sqlite-vec.

### Recommended Change Structure
```
apps/mobile/
  app/chat/[bookId].tsx          # Fix 1: getBookById -> getBookForReading
  lib/rag/pipeline.ts            # Fix 2: add server fallback when model not ready
```

### Anti-Patterns to Avoid
- **Adding a loading state bypass:** Don't skip the embedding step entirely for synced books -- they still need to be embedded for RAG to work. The fix ensures the file is downloaded first, THEN embedding proceeds.
- **Replacing on-device with server everywhere:** Server fallback is only for when the model is not downloaded. On-device should remain primary.
- **Blocking the chat screen on download:** The `getBookForReading` call should show a loading state while downloading, not freeze the UI.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| R2 file download | Custom fetch+save | `getBookForReading()` from `book-storage.ts` | Already handles presigned URL flow, DB update, and file placement |
| Server embedding | Custom embedding endpoint call | `embedTextsOnServer()` from `server-fallback.ts` | Already handles auth, error formatting, correct response parsing |
| Vector dimension matching | Manual vector size conversion | N/A -- both produce 384-dim | Both all-MiniLM-L6-v2 (on-device) and Worker /api/embed produce 384-dim vectors |

## Common Pitfalls

### Pitfall 1: Race condition between book load and embedding start
**What goes wrong:** The embedding `useEffect` (line 101) depends on `book` state. If `getBookForReading` is slow (downloading from R2), the embedding effect might fire before the book has a valid `filePath`.
**Why it happens:** React state updates are async. The book load effect sets `book`, then the embedding effect checks `book.filePath`.
**How to avoid:** The embedding effect already guards on `!book` (line 102). After the fix, `book` will only be set once `getBookForReading` resolves with a complete Book (including valid `filePath`). No additional guard needed -- the existing dependency array `[bookId, book, modelReady]` handles this correctly.

### Pitfall 2: Server fallback when model IS ready but forward throws
**What goes wrong:** The model could be "ready" (downloaded) but `forward()` could fail on a specific input.
**Why it happens:** Edge case in ExecuTorch inference.
**How to avoid:** The fallback in `pipeline.ts` should catch errors from `embedBatch` and fall back to server, not just check `isEmbeddingReady()` upfront. Use try/catch around `embedBatch` with server fallback in the catch block.

### Pitfall 3: Forgetting to import getBookForReading
**What goes wrong:** Import statement still only has `getBookById` -- TypeScript won't catch the missing async wrapper.
**How to avoid:** Update the import statement on line 14 from `getBookById` to `getBookForReading`.

### Pitfall 4: Chat input disabled state
**What goes wrong:** `chatDisabled` on line 172 checks `!modelReady`. With server fallback, chat should work even without the model.
**Why it happens:** The original design assumed on-device model was required.
**How to avoid:** After wiring server fallback, the `chatDisabled` condition and `showModelDownload` logic need updating. When server fallback is available (user is online), embedding can proceed without the model. The `modelReady` guard on the embedding `useEffect` (line 102) also needs adjustment.

### Pitfall 5: embedBook called with null/undefined filePath
**What goes wrong:** Line 110 passes `book.filePath!` (non-null assertion). If somehow the book still has no filePath after getBookForReading (e.g., R2 download failed), this will pass empty string to chunker.
**How to avoid:** Add explicit null check: `if (!book.filePath) return` before calling `embedBook`.

## Code Examples

### Fix 1: Chat screen book loading (chat/[bookId].tsx)

```typescript
// Replace import on line 14:
// OLD: import { getBookById } from '@/lib/book-storage'
// NEW:
import { getBookForReading } from '@/lib/book-storage'

// Replace useEffect on lines 78-83:
useEffect(() => {
  if (bookId) {
    getBookForReading(bookId).then(setBook).catch(err => {
      console.error('Failed to load book for chat:', err)
    })
  }
}, [bookId])
```

### Fix 2: Pipeline server fallback (pipeline.ts)

```typescript
import { getChunks } from './chunker'
import { embedBatch } from './embedder'
import { isEmbeddingReady } from './embedder'
import { embedTextsOnServer } from './server-fallback'
import { insertChunkWithVector, isBookEmbedded, deleteBookChunks } from './vector-store'

const BATCH_SIZE = 10
const BATCH_DELAY_MS = 50

async function embedBatchWithFallback(texts: string[]): Promise<number[][]> {
  if (isEmbeddingReady()) {
    try {
      return await embedBatch(texts)
    } catch (err) {
      console.warn('[pipeline] On-device embedding failed, falling back to server:', err)
    }
  }
  // Server fallback
  return embedTextsOnServer(texts)
}

export async function embedBook(
  bookId: string,
  filePath: string,
  format: 'epub' | 'pdf',
  onProgress?: (progress: number) => void
): Promise<void> {
  if (isBookEmbedded(bookId)) {
    onProgress?.(1)
    return
  }

  const chunks = await getChunks(filePath, format)
  if (chunks.length === 0) {
    onProgress?.(1)
    return
  }

  for (let i = 0; i < chunks.length; i += BATCH_SIZE) {
    const batch = chunks.slice(i, i + BATCH_SIZE)
    const embeddings = await embedBatchWithFallback(batch.map(c => c.text))

    for (let j = 0; j < batch.length; j++) {
      insertChunkWithVector(
        batch[j].id, bookId, batch[j].chunkIndex,
        batch[j].text, batch[j].chapter, embeddings[j]
      )
    }

    onProgress?.(Math.min((i + BATCH_SIZE) / chunks.length, 1))

    if (i + BATCH_SIZE < chunks.length) {
      await new Promise(r => setTimeout(r, BATCH_DELAY_MS))
    }
  }

  onProgress?.(1)
}
```

### Fix 3: Chat screen guards update (chat/[bookId].tsx)

```typescript
// The embedding useEffect needs to work without modelReady when server fallback is available.
// Remove the modelReady guard from the embedding trigger:
useEffect(() => {
  if (!bookId || !book || !book.filePath) return
  if (isBookEmbedded(bookId)) return

  setIsEmbedding(true)
  setEmbeddingTotal(100)
  setEmbeddingProcessed(0)

  embedBook(bookId, book.filePath, book.format, (progress) => {
    setEmbeddingProgress(progress)
    setEmbeddingProcessed(Math.round(progress * 100))
    if (progress >= 1) {
      setIsEmbedding(false)
    }
  }).catch((err) => {
    console.error('Embedding failed:', err)
    setIsEmbedding(false)
  })
}, [bookId, book])

// Update chatDisabled -- allow chat when book is embedded (regardless of model source):
const chatDisabled = isEmbedding || !isBookEmbedded(bookId!)
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Model required for all embedding | On-device primary + server fallback | Phase 6 (endpoint) / Phase 9 (wiring) | Users can chat about synced books immediately without waiting for 80MB model download |
| Sync-unaware book lookup | getBookForReading with on-demand download | Phase 4 (created) / Phase 9 (wiring to chat) | Synced books work in all screens, not just reader |

## Open Questions

1. **Should useRAGQuery also fall back to server for query embedding?**
   - What we know: `useRAGQuery` (line 42) checks `isEmbeddingReady()` and throws if not ready. With server fallback in the pipeline, the query-time embedding also needs fallback.
   - What's unclear: Whether to modify `useRAGQuery` or `embedSingle` in `embedder.ts`.
   - Recommendation: Add a `embedSingleWithFallback` helper in pipeline.ts (or embedder.ts) that mirrors `embedBatchWithFallback`. Update `useRAGQuery` to use it. This ensures both embedding and querying work without the on-device model.

2. **Should ModelDownloadCard still show when server fallback is available?**
   - What we know: Currently the card blocks the chat UI entirely when model is not downloaded.
   - Recommendation: Show the card as a non-blocking banner suggesting model download for faster/offline embedding, but allow chat to proceed via server fallback. This is a UX decision the planner should address.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Jest + ts-jest |
| Config file | `apps/mobile/jest.config.js` |
| Quick run command | `cd apps/mobile && npx jest --testPathPattern="<pattern>" --no-coverage` |
| Full suite command | `cd apps/mobile && npx jest --no-coverage` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| RAG-08 (pipeline fallback) | embedBook uses server fallback when model not ready | unit | `cd apps/mobile && npx jest --testPathPattern="rag-pipeline" --no-coverage` | Exists but needs fallback tests |
| RAG-08 (query fallback) | useRAGQuery embeds query via server when model not ready | unit | `cd apps/mobile && npx jest --testPathPattern="rag-query" --no-coverage` | Does not exist |
| RAG-08 (chat screen wiring) | Chat screen uses getBookForReading for synced books | manual-only | N/A -- React component with hooks, needs device | N/A |

### Sampling Rate
- **Per task commit:** `cd apps/mobile && npx jest --no-coverage`
- **Per wave merge:** `cd apps/mobile && npx jest --no-coverage`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `apps/mobile/__tests__/rag-pipeline.test.ts` -- add tests for server fallback path (embedBatchWithFallback when model not ready, when model throws)
- [ ] `apps/mobile/__tests__/rag-query-fallback.test.ts` -- test query embedding fallback (if useRAGQuery is updated)

## Sources

### Primary (HIGH confidence)
- Direct code inspection of all affected files (chat/[bookId].tsx, pipeline.ts, server-fallback.ts, embedder.ts, book-storage.ts, vector-store.ts, useEmbeddingModel.ts, useRAGQuery.ts, chunker.ts)
- Existing test files (rag-pipeline.test.ts, fallback.test.ts)
- v1.0 Milestone Audit (.planning/v1.0-MILESTONE-AUDIT.md)
- Project STATE.md decisions log

### Secondary (MEDIUM confidence)
- None needed -- all findings based on direct code inspection

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - no new libraries, all existing code
- Architecture: HIGH - both fixes are straightforward wiring changes to existing patterns
- Pitfalls: HIGH - identified from direct code analysis of race conditions and state dependencies

**Research date:** 2026-04-06
**Valid until:** 2026-05-06 (stable -- bug fixes to existing code)
