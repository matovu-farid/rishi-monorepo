# RAG service — design

**Status:** draft 2026-05-11
**Parent:** [`2026-05-11-services-and-effect-adoption-design.md`](./2026-05-11-services-and-effect-adoption-design.md) (meta-spec)
**Scope:** Wave 1, service #1 of 6. Stage 1 only (plain TypeScript). `apps/rishi-electron` renderer-side service that unifies semantic + FTS5 retrieval for one book.

## Background

Today, RAG (retrieval-augmented generation) logic in `apps/rishi-electron` is spread across:

- A main-process IPC handler `search:contextForQuery` that bundles embedding + vector search + chunk resolution into one call.
- Separate IPC handlers for `vectors:embed`, `vectors:search`, `vectors:hasFor`, `search:text`, `search:textFromVectorId`.
- A renderer-side `embed-fallback.ts` that retries embedding via the server when on-device fails — used only on the *write* (indexing) path, not the read path.
- Inline RAG retrieval code in two callers: `useChat.ts` (text chat) and `buildRealtimeAgent.ts` (voice chat). The text-chat path does a *secondary* IPC loop (`messagesGetChunkPage`) to recover the page number for each chunk, which is information already present in the database at the time of vector resolution.
- A third caller, `useBookSearch.ts`, that uses both semantic retrieval and FTS5 search independently.

There is no single owner of "given a query + book, return ranked context chunks." Every caller assembles the pipeline itself.

This refactor introduces a single renderer-side RAG service that orchestrates the read pipeline, exposes a small typed interface, and replaces the per-caller assembly. The main-process IPC handlers for fine-grained primitives (`vectors:search`, `search:textFromVectorId`, etc.) stay; the bundled `search:contextForQuery` handler is deleted because its logic moves into the renderer service.

### Pre-existing bug surfaced by exploration (out of scope, but blocks usefulness)

The indexing write path for non-EPUB books uses index name `book_${bookId}` (`vectors.ts:83`), while the read path uses `${bookId}-vectordb`. Net effect: semantic search currently returns empty for PDF / MOBI / DjVu books. This is fixed in a separate trivial PR (single-line change in `vectors.ts`) **before** this refactor lands. Without that fix, the new RAG service's `searchSemantic` will continue to return empty for non-EPUB books even after this refactor ships.

## Decision summary

| Question | Decision |
|---|---|
| Service scope | Semantic retrieval + FTS5 text search (medium scope) |
| Return shape | Rich `RankedChunk`-style records with metadata (chunkId, pageNumber, bookId, text, distance/snippet) |
| Method shape | Two methods + one predicate: `searchSemantic`, `searchText`, `isIndexed`. Distinct return types per method. |
| Naming bug | Fixed in a separate PR before this refactor |
| Error model | Plain `Error` throws + `isIndexed(bookId)` predicate to discriminate "no index" from "no matches" |
| Architecture | Orchestrating service in the renderer (not a thin facade); old `search:contextForQuery` IPC deleted |
| Interface form | Factory function `createRagService(deps)`, lazy singleton via `getRagService()` |
| Wiring site | `src/renderer/src/services/index.ts` — the one well-known wiring site for all renderer services (also serves future Wave-1 services) |
| Dependency category | Remote-but-owned (ports & adapters) for both `RagIpcChannels` and `embed` |
| Test placement | `src/renderer/src/services/rag/service.test.ts`, with in-memory adapters |
| Development workflow | TDD — red → green → commit per behavior; six behaviors, six test-impl pairs |

## Public interface

```ts
// src/renderer/src/services/rag/types.ts

export interface SemanticChunk {
  chunkId: number      // chunk_data.id
  bookId: number
  pageNumber: number
  text: string
  distance: number     // HNSW cosine distance; lower = closer
}

export interface TextMatch {
  chunkId: number
  bookId: number
  pageNumber: number
  text: string         // full chunk text
  snippet: string      // FTS5 highlighted snippet (`<mark>...</mark>` markers)
}

export interface RagIpcChannels {
  searchVectors(name: string, query: number[], dim: number, k: number):
    Promise<Array<{ id: number; distance: number }>>
  getTextFromVectorId(vectorId: number):
    Promise<{ id: number; pageNumber: number; bookId: number; data: string } | undefined>
  searchBookText(query: string, bookId: number):
    Promise<Array<{ id: number; pageNumber: number; bookId: number; data: string; snippet: string }>>
  hasVectorsForBook(bookId: number): Promise<boolean>
}

export interface RagServiceDeps {
  ipc: RagIpcChannels
  embed: (text: string) => Promise<number[]>
}
```

```ts
// src/renderer/src/services/rag/index.ts

export interface RagService {
  /**
   * Embed `query`, search the book's vector index, return top-k ranked chunks.
   * Returns [] if the book is not indexed, no matches found, or query is
   * whitespace-only. Throws Error on embedding-provider failure or IPC failure.
   */
  searchSemantic(query: string, bookId: number, k: number): Promise<SemanticChunk[]>

  /** FTS5 full-text search on the book's chunks. Returns [] if no matches or empty query. */
  searchText(query: string, bookId: number): Promise<TextMatch[]>

  /** True iff a vector index exists for this book. */
  isIndexed(bookId: number): Promise<boolean>
}

export function createRagService(deps: RagServiceDeps): RagService
```

### Usage examples (most common callers)

```ts
// useChat.ts — text chat with source attribution
const chunks = await getRagService().searchSemantic(userMessage, bookId, 5)
const systemPrompt = `Use this context:\n${chunks.map(c => c.text).join('\n\n')}`
const sourceChunks = chunks.map(c => ({
  id: c.chunkId,
  text: c.text.substring(0, 200),
  pageNumber: c.pageNumber,
}))
```

```ts
// buildRealtimeAgent.ts — voice chat tool
const bookContextExecute = async ({ queryText }: { queryText: string }) => {
  try {
    const chunks = await getRagService().searchSemantic(queryText, bookId, 3)
    return chunks.map(c => c.text)
  } catch (err) {
    captureError(err, { operation: 'realtime', step: 'bookContext_tool' })
    return ['Unable to retrieve book context at this time.']
  }
}
```

```ts
// useBookSearch.ts — search UI with semantic + text modes
const rag = getRagService()
const results = mode === 'semantic'
  ? await rag.searchSemantic(query, bookId, 10)
  : await rag.searchText(query, bookId)
```

## What's hidden behind the interface

The service owns the entire renderer-side retrieval pipeline. Callers don't see embedding (or its server fallback), don't see HNSW index naming, don't see chunk-row-to-vector-row mapping, don't see parallel chunk resolution, don't see silent-drop semantics for orphaned vector rows. They get a small typed interface: query in, ranked chunks out.

## File structure & module layout

```
src/renderer/src/services/
├── index.ts                    # one wiring site for all renderer services
└── rag/
    ├── index.ts                # public exports (RagService, types, createRagService)
    ├── types.ts                # SemanticChunk, TextMatch, dep interfaces
    ├── service.ts              # createRagService implementation
    └── service.test.ts         # boundary tests (vitest)
```

### Wiring site

```ts
// src/renderer/src/services/index.ts
import { createRagService, type RagService } from './rag'
import { embedSingleText } from '@/modules/embed-fallback'

let _rag: RagService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook,
      },
      embed: embedSingleText,
    })
  }
  return _rag
}
```

### Single additive change outside the service folder

```ts
// src/renderer/src/modules/embed-fallback.ts (additive — existing exports untouched)
export async function embedSingleText(text: string): Promise<number[]> {
  const results = await embedWithFallback([
    { text, metadata: { id: 0, pageNumber: 0, bookId: 0 } }
  ])
  if (!results[0]) throw new Error('Embed returned empty result')
  return results[0].embedding
}
```

## Dependency strategy

Both dependencies are **Remote-but-owned (ports & adapters)** per the meta-spec's categorization.

| Dep | Production adapter | Test adapter |
|---|---|---|
| `RagIpcChannels` | `window.electron.{searchVectors, getTextFromVectorId, searchBookText, hasVectorsForBook}` | Hand-rolled in-memory fake (`createFakeIpc({ vectorsByBook, chunks, ftsHits })`) returning deterministic results |
| `embed` | `embedSingleText` from `embed-fallback.ts` (tries on-device Xenova via `vectors:embed` IPC, falls back to `api.fidexa.org/api/embed` server) | Deterministic embedder: `text => hash(text) → 384-dim vector`. Same input always produces same vector. |

Tests do **not** require: Electron runtime, main process, sqlite, HNSW, real embedding model. The service is testable as plain code under vitest.

## Internals (orchestration flow)

```ts
// service.ts (illustrative — final implementation may differ in style but must match behavior)

const indexName = (bookId: number) => `${bookId}-vectordb`
const EMBEDDING_DIM = 384

export function createRagService(deps: RagServiceDeps): RagService {
  const { ipc, embed } = deps

  return {
    async searchSemantic(query, bookId, k) {
      if (query.trim().length === 0) return []

      const vector = await embed(query)

      const hits = await ipc.searchVectors(indexName(bookId), vector, EMBEDDING_DIM, k)
      if (hits.length === 0) return []

      const chunks = await Promise.all(
        hits.map(h => ipc.getTextFromVectorId(h.id))
      )

      const result: SemanticChunk[] = []
      for (let i = 0; i < hits.length; i++) {
        const chunk = chunks[i]
        if (!chunk) continue
        result.push({
          chunkId: chunk.id,
          bookId: chunk.bookId,
          pageNumber: chunk.pageNumber,
          text: chunk.data,
          distance: hits[i].distance,
        })
      }
      return result
    },

    async searchText(query, bookId) {
      if (query.trim().length === 0) return []
      const hits = await ipc.searchBookText(query, bookId)
      return hits.map(h => ({
        chunkId: h.id,
        bookId: h.bookId,
        pageNumber: h.pageNumber,
        text: h.data,
        snippet: h.snippet,
      }))
    },

    async isIndexed(bookId) {
      return ipc.hasVectorsForBook(bookId)
    },
  }
}
```

### Behavioral notes baked into the contract

- **Empty / whitespace-only query → `[]` immediately.** No embed call. No IPC. Defensive guard for accidental empty-input UI paths.
- **Vector search miss → `[]`.** Indistinguishable at the result level from "indexed but no matches" — callers that need to differentiate use `isIndexed(bookId)` separately.
- **Orphaned vector hits are silently dropped.** If a vector row exists in HNSW but the chunk_data row was deleted, that hit is skipped. The result array may be shorter than `k`.
- **Embed failure → throws.** Callers (`buildRealtimeAgent`, `useChat`, `useBookSearch`) already wrap their RAG calls in try/catch.
- **Parallel chunk resolution.** Promise.all over the hits; small latency improvement over today's sequential loop, no semantic change.

### Explicitly NOT added (YAGNI per the meta-spec scope guard)

- No request dedup for identical concurrent queries.
- No result caching across calls.
- No retry on IPC failure (the IPC layer doesn't have transient failures in our setup).
- No batching of embed calls.

Each of these is a candidate for Stage 2 Effect retrofit *if* RAG hits the rubric (predicted: it won't), but is explicitly out of scope for Stage 1.

## Boundary test scenarios

Six tests, all at the public interface. No tests poke internals.

### Test 1: `searchSemantic` happy path — embed → search → resolve → assemble

Setup:
- Fake `embed` returns a deterministic vector for the input query.
- Fake `ipc.searchVectors` returns `[{ id: 10, distance: 0.1 }, { id: 20, distance: 0.3 }]` when called with book `5`.
- Fake `ipc.getTextFromVectorId` returns chunk records for ids 10 and 20.

Assertions:
- Result length === 2.
- Result[0] === `{ chunkId: 10, distance: 0.1, text: <chunk 10 data>, pageNumber: <chunk 10 page>, bookId: 5 }`.
- Order preserved (lowest distance first, matching vector search order).
- `embed` called exactly once with the query string.
- `ipc.searchVectors` called with index name `"5-vectordb"`, the embedded vector, dim `384`, and the k from args.

### Test 2: `searchSemantic` returns `[]` immediately for empty / whitespace query

Setup: any fake deps.

Cases: `searchSemantic("", 5, 3)` and `searchSemantic("   \n\t", 5, 3)`.

Assertions:
- Both return `[]`.
- `embed` is **never** called.
- `ipc.searchVectors` is **never** called.

### Test 3: `searchSemantic` silently drops vector hits whose chunk row is missing

Setup:
- Fake `ipc.searchVectors` returns 3 hits: ids 10, 20, 30.
- Fake `ipc.getTextFromVectorId` returns valid chunks for 10 and 30 but `undefined` for 20 (simulates orphaned vector).

Assertions:
- Result length === 2.
- Result contains chunkIds 10 and 30, in that order.
- No error thrown.

### Test 4: `searchSemantic` propagates `embed` failure

Setup: fake `embed` rejects with `new Error("embedding provider unavailable")`.

Assertions:
- `searchSemantic("hello", 5, 3)` rejects with the same Error (or one wrapping its message).
- `ipc.searchVectors` is **never** called.

### Test 5: `searchText` happy path with snippet preserved + empty-query short-circuit

Setup:
- Fake `ipc.searchBookText` returns `[{ id: 7, pageNumber: 12, bookId: 5, data: "full chunk text", snippet: "the <mark>query</mark> appears here" }]`.

Assertions:
- Result length === 1.
- Result[0] === `{ chunkId: 7, bookId: 5, pageNumber: 12, text: "full chunk text", snippet: "the <mark>query</mark> appears here" }`.
- `searchText("", 5)` returns `[]` without calling IPC.

### Test 6: `isIndexed` round-trips IPC result

Setup: fake `ipc.hasVectorsForBook(5)` returns `true`; `ipc.hasVectorsForBook(99)` returns `false`.

Assertions:
- `isIndexed(5)` resolves to `true`.
- `isIndexed(99)` resolves to `false`.

### Tests we explicitly do NOT add

- Performance / parallelism assertions — not part of the public contract.
- Retry / cache behavior — service has none.

## Caller migration

| File | Current | After |
|---|---|---|
| `src/renderer/src/hooks/useChat.ts` (~lines 132-150) | `getContextForQuery({ queryText: text, bookId, k: 5 })` returning `string[]`; secondary loop calling `window.electron.messagesGetChunkPage` to map text → pageNumber | `getRagService().searchSemantic(text, bookId, 5)` returning `SemanticChunk[]`; **delete the `messagesGetChunkPage` loop entirely** — pageNumber comes from `chunks[i].pageNumber` |
| `src/renderer/src/modules/buildRealtimeAgent.ts` (~lines 57-66) | `getContextForQuery({ bookId, queryText, k: 3 })` returning `string[]` consumed by OpenAI tool | `getRagService().searchSemantic(queryText, bookId, 3)`; map to `string[]` at the tool boundary: `chunks.map(c => c.text)` |
| `src/renderer/src/hooks/useBookSearch.ts` (~line 113) | `getContextForQuery(...)` for semantic mode; existing `searchBookText(...)` call for FTS mode | `getRagService().searchSemantic(...)` for semantic; `getRagService().searchText(...)` for FTS |

## Files / code to delete

| Location | What to remove |
|---|---|
| `src/main/ipc/search.ts:27-59` | The entire `search:contextForQuery` handler. **Keep** `search:text` and `search:textFromVectorId` handlers (still used by the service's IPC adapter) |
| `src/preload/index.ts` | The `getContextForQuery` export on the contextBridge |
| `src/preload/types.ts` | The `getContextForQuery` field on the API type |
| `src/renderer/src/lib/api.ts` | The `getContextForQuery` wrapper function |
| Any obsolete tests touching the now-deleted shallow code | Per meta-spec: tests describing implementation get deleted in the same commit as the migration |

## Out of scope

- **Vector index naming bug fix** — separate trivial PR before this refactor lands. Changes `vectors.ts:83` from `` `book_${bookId}` `` to `` `${bookId}-vectordb` ``.
- **IPC channel reorganization / renaming** — deferred to the future IPC consolidation spec.
- **embed-fallback location** — `embed-fallback.ts` stays in `src/renderer/src/modules/` for now. It may move into the Book Import service in Wave 2.
- **Tests on existing callers (`chatStore.test.ts`, etc.)** — if they cover the now-deleted retrieval code, they get deleted in the migration commit. Otherwise untouched.

## Development workflow — TDD

Strict TDD: red → green → commit per behavior. Each test-implementation pair is its own commit. No "implement everything then write tests" commits.

### PR commit sequence

1. **Scaffold.** Create `services/rag/` folder with `types.ts` (full type definitions) and an empty `createRagService` stub in `service.ts` that throws "not implemented" from each method. Set up `service.test.ts` with fake adapter helper functions. Commit.
2. **Test 1 + impl (semantic happy path).** Write Test 1. Run, observe red. Implement `searchSemantic`'s embed → search → resolve → assemble pipeline. Run, observe green. Commit.
3. **Test 2 + impl (empty-query short-circuit).** Write Test 2. Red. Add the whitespace-guard early return. Green. Commit.
4. **Test 3 + impl (drop unresolved chunks).** Write Test 3. Red. Refine the assembly loop to skip `undefined`. Green. Commit.
5. **Test 4 + impl (embed failure propagates).** Write Test 4. Red. Verify no special handling is needed (Promise rejection already propagates). Green. Commit.
6. **Test 5 + impl (FTS happy path + empty query).** Write Test 5. Red. Implement `searchText`. Green. Commit.
7. **Test 6 + impl (isIndexed round-trip).** Write Test 6. Red. Implement `isIndexed`. Green. Commit.
8. **Wiring.** Add `embedSingleText` to `embed-fallback.ts`; create `services/index.ts` with `getRagService()`. No new tests (wiring is composition, not behavior). Commit.
9. **Migrate `useChat`.** Swap the `getContextForQuery` + `messagesGetChunkPage` loop for `getRagService().searchSemantic(...)`. Verify existing `useChat`-adjacent tests still pass or are updated. Commit.
10. **Migrate `buildRealtimeAgent`.** Swap to service + `chunks.map(c => c.text)` at the tool boundary. Commit.
11. **Migrate `useBookSearch`.** Swap both semantic and FTS paths to the service. Commit.
12. **Delete dead code.** Remove `search:contextForQuery` handler, preload export, `api.ts` wrapper, type. Commit.
13. **Final verification.** `tsc`, `eslint`, `vitest` clean across the whole app. No new commit unless something fails.

### Workflow rules

- Each commit either adds a red test, makes a red test green, or completes a non-behavioral step. No batched "write everything then run tests" commits.
- After step 7, all 6 service tests are green. Steps 8–12 are migration / cleanup and add no new tests at the RAG-service boundary.
- If a caller migration breaks a pre-existing test that was testing now-deleted shallow code, delete the obsolete test in the same commit as the migration.

### Expected diff size

Roughly ~400 lines added (service + tests + wiring), ~150 lines removed (deletions + caller cleanups). Net: small. One reviewer, one sitting.

## Definition of done

Per the meta-spec's standard. This service refactor ships when:

1. `src/renderer/src/services/rag/index.ts` is the single public-facing module exporting the service.
2. All three callers (`useChat`, `buildRealtimeAgent`, `useBookSearch`) use `getRagService()`.
3. The old `search:contextForQuery` IPC handler, preload export, and `api.ts` wrapper are **deleted**, not kept as shims.
4. All six boundary tests pass.
5. `tsc`, `eslint`, `vitest` clean across the app.
