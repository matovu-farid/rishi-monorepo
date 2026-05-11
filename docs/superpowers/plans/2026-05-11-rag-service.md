# RAG Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a renderer-side RAG service in `apps/rishi-electron` that unifies semantic + FTS5 retrieval behind a 3-method interface, replace three callers' inline retrieval code, and delete the bundled `search:contextForQuery` IPC handler.

**Architecture:** Plain TypeScript factory function `createRagService(deps)` returning a `RagService` with `searchSemantic`, `searchText`, `isIndexed`. Two injected dependencies (`RagIpcChannels`, `embed`) — both ports & adapters. Production wiring at `src/renderer/src/services/index.ts` via `getRagService()`. Tests use vitest with hand-rolled vi.fn() spy adapters; no Electron / sqlite / vector DB required at test time.

**Tech Stack:** TypeScript 5, Vitest 4, Electron 39 IPC, existing `embed-fallback.ts` (Xenova on-device + server fallback).

**Spec:** [`docs/superpowers/specs/2026-05-11-rag-service-design.md`](../specs/2026-05-11-rag-service-design.md)

**Parent meta-spec:** [`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md`](../specs/2026-05-11-services-and-effect-adoption-design.md)

---

## Plan overview

- **Task 0 — Prerequisite (separate PR):** Fix the vector index naming bug in `vectors.ts:83` so non-EPUB books actually have searchable indices. **This is a separate PR that must merge before Task 1 begins.**
- **Tasks 1–8 — Build the service (TDD):** Scaffold, then six red→green test/implementation pairs, then a final scaffold-wiring commit. After Task 8, the service is fully implemented and tested in isolation but not yet used by any caller.
- **Tasks 9–11 — Migrate callers:** Replace inline RAG code in `useChat`, `buildRealtimeAgent`, `useBookSearch` with `getRagService()` calls. One caller per commit.
- **Task 12 — Delete dead code:** Remove the now-unused `search:contextForQuery` IPC handler, preload export, and `api.ts` wrapper.
- **Task 13 — Final verification:** `tsc`, `eslint`, `vitest` all clean.

All paths below are relative to the monorepo root (`/Users/faridmatovu/projects/rishi-monorepo`). All commands should be run from `apps/rishi-electron` unless otherwise stated.

---

## Task 0: Fix vector index naming bug (SEPARATE PR — land before Task 1)

**This is a one-line bug fix that ships as its own PR before the RAG refactor begins.** Without it, the new service's `searchSemantic` will continue to return empty results for PDF / MOBI / DjVu books even after this plan is done.

**Files:**
- Modify: `apps/rishi-electron/src/main/ipc/vectors.ts:83`

- [ ] **Step 1: Create a new branch off main**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git checkout main
git pull
git checkout -b fix/vector-index-naming
```

- [ ] **Step 2: Apply the one-line change**

In `apps/rishi-electron/src/main/ipc/vectors.ts`, locate line 83:

```ts
await vectorSave(`book_${bookId}`, embedResults[0].dim, vectors)
```

Change it to:

```ts
await vectorSave(`${bookId}-vectordb`, embedResults[0].dim, vectors)
```

This aligns the write-side naming (used by PDF/MOBI/DjVu via the `vectors:processJob` IPC handler) with the read-side naming (used by `search.ts:36` and by EPUB indexing in `process_epub.ts:77`).

- [ ] **Step 3: Verify typecheck still passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes with no errors.

- [ ] **Step 4: Commit and open PR**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/ipc/vectors.ts
git commit -m "fix(electron): align processJob vector index name with read path

PDFs/MOBI/DjVu books wrote vectors under 'book_\${bookId}' but the read
path looks up '\${bookId}-vectordb'. Net effect: semantic search silently
returned empty for non-EPUB books. Existing books re-index automatically
on next open via the format handlers' hasVectorsForBook check."
git push -u origin fix/vector-index-naming
gh pr create --title "fix(electron): align processJob vector index name with read path" --body "$(cat <<'EOF'
## Summary
- Single-line fix in \`vectors.ts:83\`: write side now uses \`\${bookId}-vectordb\` to match the read side.
- Without this, semantic search silently returned empty for PDFs/MOBI/DjVu.
- Existing books re-index on next open via the existing \`hasVectorsForBook\` gate; one-time slower open per existing PDF, then everything works.

## Test plan
- [ ] Open an existing PDF; verify it re-embeds (logs / dev tools).
- [ ] Trigger semantic search on the re-indexed PDF; verify non-empty results.
- [ ] Open an EPUB previously indexed; verify it does NOT re-index (already at correct name).
EOF
)"
```

- [ ] **Step 5: Wait for the PR to merge to main before continuing**

Do not start Task 1 until this PR is merged. The remaining tasks assume the bug fix is on `main`.

---

## Task 1: Scaffold service folder, types, and stub implementation

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/rag/types.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/rag/service.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/rag/index.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`

- [ ] **Step 1: Create a new branch off main (with Task 0 merged)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git checkout main
git pull
git checkout -b refactor/rag-service
```

- [ ] **Step 2: Create `types.ts` with all type definitions**

Create `apps/rishi-electron/src/renderer/src/services/rag/types.ts`:

```ts
export interface SemanticChunk {
  chunkId: number
  bookId: number
  pageNumber: number
  text: string
  distance: number
}

export interface TextMatch {
  chunkId: number
  bookId: number
  pageNumber: number
  text: string
  snippet: string
}

export interface RagIpcChannels {
  searchVectors(
    name: string,
    query: number[],
    dim: number,
    k: number
  ): Promise<Array<{ id: number; distance: number }>>
  getTextFromVectorId(
    vectorId: number
  ): Promise<{ id: number; pageNumber: number; bookId: number; data: string } | undefined>
  searchBookText(
    query: string,
    bookId: number
  ): Promise<
    Array<{ id: number; pageNumber: number; bookId: number; data: string; snippet: string }>
  >
  hasVectorsForBook(bookId: number): Promise<boolean>
}

export interface RagServiceDeps {
  ipc: RagIpcChannels
  embed: (text: string) => Promise<number[]>
}

export interface RagService {
  searchSemantic(query: string, bookId: number, k: number): Promise<SemanticChunk[]>
  searchText(query: string, bookId: number): Promise<TextMatch[]>
  isIndexed(bookId: number): Promise<boolean>
}
```

- [ ] **Step 3: Create `service.ts` with a "not implemented" stub**

Create `apps/rishi-electron/src/renderer/src/services/rag/service.ts`:

```ts
import type { RagService, RagServiceDeps } from './types'

export function createRagService(_deps: RagServiceDeps): RagService {
  return {
    async searchSemantic(_query, _bookId, _k) {
      throw new Error('not implemented')
    },
    async searchText(_query, _bookId) {
      throw new Error('not implemented')
    },
    async isIndexed(_bookId) {
      throw new Error('not implemented')
    },
  }
}
```

- [ ] **Step 4: Create `index.ts` re-exporting public surface**

Create `apps/rishi-electron/src/renderer/src/services/rag/index.ts`:

```ts
export type {
  SemanticChunk,
  TextMatch,
  RagIpcChannels,
  RagServiceDeps,
  RagService,
} from './types'
export { createRagService } from './service'
```

- [ ] **Step 5: Create `service.test.ts` with shared fake-adapter helpers (no actual tests yet)**

Create `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`:

```ts
import { vi } from 'vitest'
import type { RagIpcChannels } from './index'

/**
 * Build a fake RagIpcChannels. All methods are vi.fn() spies returning
 * sensible defaults; override any individual method via the argument.
 */
export function makeIpc(overrides: Partial<RagIpcChannels> = {}): RagIpcChannels {
  return {
    searchVectors: vi.fn().mockResolvedValue([]),
    getTextFromVectorId: vi.fn().mockResolvedValue(undefined),
    searchBookText: vi.fn().mockResolvedValue([]),
    hasVectorsForBook: vi.fn().mockResolvedValue(false),
    ...overrides,
  }
}

/**
 * Build a deterministic fake embed function. Returns a fixed 384-dim vector
 * regardless of input. Real assertions in tests use spy methods, not vector content.
 */
export function makeEmbed(): ReturnType<typeof vi.fn> {
  return vi.fn().mockResolvedValue(new Array(384).fill(0.5))
}
```

Note: vitest discovers `*.test.ts` automatically; no config change needed.

- [ ] **Step 6: Verify the test file is discovered and the scaffold typechecks**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

```bash
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: vitest finds the file and reports "No test found" or 0 tests passing. Both are OK — the helpers don't define `it()` blocks yet.

- [ ] **Step 7: Commit the scaffold**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/
git commit -m "refactor(rag): scaffold renderer-side RAG service folder

Types, empty createRagService stub, public re-exports, and shared
test helpers (makeIpc, makeEmbed). No behavior yet; subsequent
commits add tests + minimal implementation per behavior (TDD)."
```

---

## Task 2: TDD pair — Test 1: searchSemantic happy path

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.ts`

- [ ] **Step 1: Add Test 1 to `service.test.ts` (the failing test)**

Append to `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createRagService } from './index'

describe('RagService.searchSemantic', () => {
  it('embeds the query, searches vectors, resolves chunks, and assembles results', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc({
      searchVectors: vi.fn().mockResolvedValue([
        { id: 10, distance: 0.1 },
        { id: 20, distance: 0.3 },
      ]),
      getTextFromVectorId: vi.fn(async (id: number) => {
        if (id === 10) return { id: 10, pageNumber: 3, bookId: 5, data: 'chunk 10 text' }
        if (id === 20) return { id: 20, pageNumber: 7, bookId: 5, data: 'chunk 20 text' }
        return undefined
      }),
    })
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('hello world', 5, 3)

    expect(result).toEqual([
      { chunkId: 10, bookId: 5, pageNumber: 3, text: 'chunk 10 text', distance: 0.1 },
      { chunkId: 20, bookId: 5, pageNumber: 7, text: 'chunk 20 text', distance: 0.3 },
    ])
    expect(embed).toHaveBeenCalledTimes(1)
    expect(embed).toHaveBeenCalledWith('hello world')
    expect(ipc.searchVectors).toHaveBeenCalledTimes(1)
    expect(ipc.searchVectors).toHaveBeenCalledWith(
      '5-vectordb',
      expect.any(Array),
      384,
      3
    )
  })
})
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 1 test fails with "not implemented" thrown from `searchSemantic`.

- [ ] **Step 3: Implement `searchSemantic` (minimal — happy path only)**

Replace the contents of `apps/rishi-electron/src/renderer/src/services/rag/service.ts`:

```ts
import type {
  RagService,
  RagServiceDeps,
  SemanticChunk,
} from './types'

const EMBEDDING_DIM = 384
const indexName = (bookId: number): string => `${bookId}-vectordb`

export function createRagService(deps: RagServiceDeps): RagService {
  const { ipc, embed } = deps

  return {
    async searchSemantic(query, bookId, k) {
      const vector = await embed(query)
      const hits = await ipc.searchVectors(indexName(bookId), vector, EMBEDDING_DIM, k)
      const chunks = await Promise.all(hits.map((h) => ipc.getTextFromVectorId(h.id)))
      const result: SemanticChunk[] = []
      for (let i = 0; i < hits.length; i++) {
        const chunk = chunks[i]
        // (orphan handling added in a later commit; happy path assumes all resolve)
        result.push({
          chunkId: chunk!.id,
          bookId: chunk!.bookId,
          pageNumber: chunk!.pageNumber,
          text: chunk!.data,
          distance: hits[i].distance,
        })
      }
      return result
    },
    async searchText(_query, _bookId) {
      throw new Error('not implemented')
    },
    async isIndexed(_bookId) {
      throw new Error('not implemented')
    },
  }
}
```

- [ ] **Step 4: Run the test — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/service.test.ts apps/rishi-electron/src/renderer/src/services/rag/service.ts
git commit -m "test(rag): searchSemantic happy path (embed → search → resolve → assemble)"
```

---

## Task 3: TDD pair — Test 2: empty/whitespace query short-circuit

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.ts`

- [ ] **Step 1: Add Test 2 to `service.test.ts` (failing)**

Add inside the `describe('RagService.searchSemantic', ...)` block:

```ts
  it('returns [] immediately for empty query without calling embed or IPC', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('', 5, 3)

    expect(result).toEqual([])
    expect(embed).not.toHaveBeenCalled()
    expect(ipc.searchVectors).not.toHaveBeenCalled()
  })

  it('returns [] immediately for whitespace-only query', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('   \n\t  ', 5, 3)

    expect(result).toEqual([])
    expect(embed).not.toHaveBeenCalled()
    expect(ipc.searchVectors).not.toHaveBeenCalled()
  })
```

- [ ] **Step 2: Run tests — expect 2 RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 2 tests fail (the new ones); 1 passes (Test 1). The failure is in `embed` getting called even on empty input.

- [ ] **Step 3: Add the whitespace guard at the top of `searchSemantic`**

In `apps/rishi-electron/src/renderer/src/services/rag/service.ts`, modify `searchSemantic` to add the guard as the first line:

```ts
    async searchSemantic(query, bookId, k) {
      if (query.trim().length === 0) return []
      const vector = await embed(query)
      // ... rest unchanged
```

- [ ] **Step 4: Run tests — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/service.test.ts apps/rishi-electron/src/renderer/src/services/rag/service.ts
git commit -m "test(rag): searchSemantic short-circuits on empty/whitespace query"
```

---

## Task 4: TDD pair — Test 3: silently drop orphaned vector hits

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.ts`

- [ ] **Step 1: Add Test 3 (failing)**

Add inside the same `describe`:

```ts
  it('silently drops vector hits whose chunk row is missing', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc({
      searchVectors: vi.fn().mockResolvedValue([
        { id: 10, distance: 0.1 },
        { id: 20, distance: 0.2 },
        { id: 30, distance: 0.3 },
      ]),
      getTextFromVectorId: vi.fn(async (id: number) => {
        if (id === 10) return { id: 10, pageNumber: 1, bookId: 5, data: 'ten' }
        if (id === 20) return undefined // orphaned vector
        if (id === 30) return { id: 30, pageNumber: 3, bookId: 5, data: 'thirty' }
        return undefined
      }),
    })
    const service = createRagService({ ipc, embed })

    const result = await service.searchSemantic('q', 5, 3)

    expect(result).toHaveLength(2)
    expect(result.map((c) => c.chunkId)).toEqual([10, 30])
  })
```

- [ ] **Step 2: Run tests — expect 1 RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 1 new test fails — Test 3 throws (current code uses `chunk!.id` and crashes on undefined). Other 3 tests still pass.

- [ ] **Step 3: Refine `searchSemantic`'s assembly loop to skip undefined chunks**

In `apps/rishi-electron/src/renderer/src/services/rag/service.ts`, replace the for-loop inside `searchSemantic` with the guarded version:

```ts
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
```

Also remove the now-unneeded `chunk!` non-null assertions.

- [ ] **Step 4: Run tests — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/service.test.ts apps/rishi-electron/src/renderer/src/services/rag/service.ts
git commit -m "test(rag): searchSemantic drops orphaned vector hits silently"
```

---

## Task 5: TDD pair — Test 4: embed failure propagates

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`

- [ ] **Step 1: Add Test 4 (failing or green — see step 2)**

Add inside the same `describe`:

```ts
  it('propagates embed failure and does not call searchVectors', async () => {
    const embed = vi.fn().mockRejectedValue(new Error('embedding provider unavailable'))
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    await expect(service.searchSemantic('hello', 5, 3)).rejects.toThrow(
      'embedding provider unavailable'
    )
    expect(ipc.searchVectors).not.toHaveBeenCalled()
  })
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 5 tests pass — including this new one. Why? Because Promise rejection from `embed` naturally propagates through `await` without any special handling. This test documents the expected behavior; no code change is needed.

If the test unexpectedly fails, investigate before continuing.

- [ ] **Step 3: Commit (test-only commit, no impl change)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/service.test.ts
git commit -m "test(rag): searchSemantic propagates embed failure"
```

---

## Task 6: TDD pair — Test 5: searchText happy path + empty query

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.ts`

- [ ] **Step 1: Add Test 5 (failing)**

Append to `service.test.ts` after the `RagService.searchSemantic` describe block:

```ts
describe('RagService.searchText', () => {
  it('passes through FTS5 results with snippet preserved', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc({
      searchBookText: vi.fn().mockResolvedValue([
        {
          id: 7,
          pageNumber: 12,
          bookId: 5,
          data: 'full chunk text',
          snippet: 'the <mark>query</mark> appears here',
        },
      ]),
    })
    const service = createRagService({ ipc, embed })

    const result = await service.searchText('query', 5)

    expect(result).toEqual([
      {
        chunkId: 7,
        bookId: 5,
        pageNumber: 12,
        text: 'full chunk text',
        snippet: 'the <mark>query</mark> appears here',
      },
    ])
    expect(ipc.searchBookText).toHaveBeenCalledTimes(1)
    expect(ipc.searchBookText).toHaveBeenCalledWith('query', 5)
  })

  it('returns [] for empty query without calling IPC', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc()
    const service = createRagService({ ipc, embed })

    const result = await service.searchText('', 5)

    expect(result).toEqual([])
    expect(ipc.searchBookText).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run tests — expect 2 RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 2 new tests fail (both throw "not implemented").

- [ ] **Step 3: Implement `searchText`**

In `apps/rishi-electron/src/renderer/src/services/rag/service.ts`, also add `TextMatch` to the type import:

```ts
import type {
  RagService,
  RagServiceDeps,
  SemanticChunk,
  TextMatch,
} from './types'
```

Replace the `searchText` stub body:

```ts
    async searchText(query, bookId) {
      if (query.trim().length === 0) return []
      const hits = await ipc.searchBookText(query, bookId)
      return hits.map<TextMatch>((h) => ({
        chunkId: h.id,
        bookId: h.bookId,
        pageNumber: h.pageNumber,
        text: h.data,
        snippet: h.snippet,
      }))
    },
```

- [ ] **Step 4: Run tests — expect 7 GREEN**

```bash
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/service.test.ts apps/rishi-electron/src/renderer/src/services/rag/service.ts
git commit -m "test(rag): searchText pass-through + empty-query short-circuit"
```

---

## Task 7: TDD pair — Test 6: isIndexed round-trips IPC result

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/rag/service.ts`

- [ ] **Step 1: Add Test 6 (failing)**

Append to `service.test.ts`:

```ts
describe('RagService.isIndexed', () => {
  it('returns true when the book has a vector index', async () => {
    const embed = makeEmbed()
    const ipc = makeIpc({
      hasVectorsForBook: vi.fn(async (bookId: number) => bookId === 5),
    })
    const service = createRagService({ ipc, embed })

    await expect(service.isIndexed(5)).resolves.toBe(true)
    await expect(service.isIndexed(99)).resolves.toBe(false)
  })
})
```

- [ ] **Step 2: Run tests — expect 1 RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 1 new test fails ("not implemented").

- [ ] **Step 3: Implement `isIndexed`**

In `apps/rishi-electron/src/renderer/src/services/rag/service.ts`, replace the `isIndexed` stub body:

```ts
    async isIndexed(bookId) {
      return ipc.hasVectorsForBook(bookId)
    },
```

- [ ] **Step 4: Run tests — expect 8 GREEN**

```bash
pnpm vitest run src/renderer/src/services/rag/service.test.ts
```

Expected: 8 tests pass. The service is now fully implemented.

- [ ] **Step 5: Verify typecheck passes**

```bash
pnpm typecheck
```

Expected: passes (no errors).

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/rag/service.test.ts apps/rishi-electron/src/renderer/src/services/rag/service.ts
git commit -m "test(rag): isIndexed round-trips hasVectorsForBook"
```

---

## Task 8: Wiring — embedSingleText helper + getRagService() singleton

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/embed-fallback.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/index.ts`

- [ ] **Step 1: Add the `embedSingleText` helper to `embed-fallback.ts`**

Open `apps/rishi-electron/src/renderer/src/modules/embed-fallback.ts` and append (do not modify existing exports):

```ts
export async function embedSingleText(text: string): Promise<number[]> {
  const results = await embedWithFallback([
    { text, metadata: { id: 0, pageNumber: 0, bookId: 0 } },
  ])
  if (!results[0]) throw new Error('Embed returned empty result')
  return results[0].embedding
}
```

If `embedWithFallback` is not exported from that module under that exact name, locate the existing exported function that performs `EmbedParam[] → EmbedResult[]` with server fallback and call that instead — the helper's job is to wrap whatever the existing single-batch fallback function is into a `(text: string) => Promise<number[]>`.

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Create the wiring site `services/index.ts`**

Create `apps/rishi-electron/src/renderer/src/services/index.ts`:

```ts
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

If `@/modules/embed-fallback` is not the alias used in this codebase, use the same import style as other renderer modules (check imports in `useChat.ts` or `buildRealtimeAgent.ts` for the convention).

- [ ] **Step 4: Verify typecheck passes**

```bash
pnpm typecheck
```

Expected: passes. If `window.electron.searchVectors` etc. don't exist on the typed interface, check `apps/rishi-electron/src/preload/types.ts` — they should be present per the spec's interface contract.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

```bash
pnpm test
```

Expected: all tests pass, including the 8 new RAG tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/modules/embed-fallback.ts apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(rag): wire production singleton + embedSingleText helper

getRagService() is the lazy-singleton entry point used by callers in the
next commits. embedSingleText adapts embed-fallback to the service's
(text) => Promise<number[]> dependency shape."
```

---

## Task 9: Migrate caller — `useChat`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/hooks/useChat.ts`

- [ ] **Step 1: Open `useChat.ts` and locate the RAG block (around lines 132-150)**

The relevant block currently does:

```ts
// 3. RAG retrieval
const contextTexts = await getContextForQuery({
  queryText: text,
  bookId,
  k: 5
})

// 4. Get source chunk metadata from chunk_data table
const sourceChunks: SourceChunk[] = []
for (const contextText of contextTexts) {
  const pageNumber = await window.electron.messagesGetChunkPage(bookId, contextText)
  if (pageNumber !== null) {
    sourceChunks.push({
      id: 0,
      text: contextText.substring(0, 200),
      pageNumber
    })
  }
}

// 5. Build system prompt with RAG context
const systemPrompt = `... ${contextTexts.join('\n\n')}`
```

- [ ] **Step 2: Replace the RAG block with a single service call**

Add the import at the top of the file (alongside other imports):

```ts
import { getRagService } from '@/services'
```

Replace the block above with:

```ts
// 3. RAG retrieval
const chunks = await getRagService().searchSemantic(text, bookId, 5)

// 4. Map directly to source chunk metadata — pageNumber already present
const sourceChunks: SourceChunk[] = chunks.map((c) => ({
  id: c.chunkId,
  text: c.text.substring(0, 200),
  pageNumber: c.pageNumber,
}))

// 5. Build system prompt with RAG context
const systemPrompt = `... ${chunks.map((c) => c.text).join('\n\n')}`
```

Preserve the full system prompt template literal — only the source of context strings changes (from `contextTexts` to `chunks.map((c) => c.text)`).

Also remove the now-unused `getContextForQuery` import if it appears at the top of the file.

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes. If `SourceChunk['id']` is required and `c.chunkId` doesn't match its type, adjust the type or coerce — but the spec uses `c.chunkId` (a number from the chunk_data row), which should match the existing `SourceChunk['id']: number`.

- [ ] **Step 4: Run tests (existing useChat-adjacent tests + RAG tests)**

```bash
pnpm test
```

Expected: all tests pass. If a pre-existing test on `useChat` was asserting against the `messagesGetChunkPage` loop's behavior, update it to reflect the new flow.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/hooks/useChat.ts
git commit -m "refactor(rag): migrate useChat to RAG service

Replaces inline getContextForQuery + messagesGetChunkPage loop with a
single getRagService().searchSemantic() call. pageNumber now comes back
with the chunk metadata instead of a secondary IPC roundtrip."
```

---

## Task 10: Migrate caller — `buildRealtimeAgent`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`

- [ ] **Step 1: Open `buildRealtimeAgent.ts` and locate `bookContextExecute` (around lines 57-66)**

Current shape:

```ts
const bookContextExecute = async ({ queryText }: { queryText: string }) => {
  try {
    const context = await getContextForQuery({ bookId, queryText, k: 3 })
    return context
  } catch (err) {
    captureError(err, { operation: 'realtime', step: 'bookContext_tool' })
    return ['Unable to retrieve book context at this time.']
  }
}
```

- [ ] **Step 2: Replace with service call + string mapping at the tool boundary**

Add the import at the top:

```ts
import { getRagService } from '@/services'
```

Replace `bookContextExecute` with:

```ts
const bookContextExecute = async ({ queryText }: { queryText: string }) => {
  try {
    const chunks = await getRagService().searchSemantic(queryText, bookId, 3)
    return chunks.map((c) => c.text)
  } catch (err) {
    captureError(err, { operation: 'realtime', step: 'bookContext_tool' })
    return ['Unable to retrieve book context at this time.']
  }
}
```

Remove the now-unused `getContextForQuery` import if present.

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 4: Run tests**

```bash
pnpm test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts
git commit -m "refactor(rag): migrate buildRealtimeAgent to RAG service

Voice chat's bookContext tool now uses getRagService().searchSemantic.
The OpenAI tool boundary still returns string[], extracted via chunks.map(c => c.text)."
```

---

## Task 11: Migrate caller — `useBookSearch`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/hooks/useBookSearch.ts`

- [ ] **Step 1: Open `useBookSearch.ts` and study its two search functions**

`runExactSearch` (around lines 54-101) has two branches: an EPUB-specific spine-search path (untouched by this refactor) and an FTS5 path (line 81) using `searchBookText` that we will migrate.

`runSemanticSearch` (around lines 104-138) uses `getContextForQuery` plus a `messagesGetChunkPage` loop — same pattern useChat had.

Both produce `BookSearchResult` objects (interface defined at lines 6-14 of the file):

```ts
interface BookSearchResult {
  id: string
  snippet: string
  highlightedSnippet?: string
  pageNumber?: number
  chapter?: string
  cfi?: string
  mode: SearchMode
}
```

- [ ] **Step 2: Add the service import; remove the old imports**

At the top of the file, replace:

```ts
import { searchBookText, getContextForQuery } from '@/lib/api'
```

with:

```ts
import { getRagService } from '@/services'
```

- [ ] **Step 3: Migrate the FTS5 branch in `runExactSearch`**

Replace lines 81-91 (the `searchBookText` call and the `setResults(...ftsResults.map(...))` mapping) with:

```ts
          const ftsResults = await getRagService().searchText(cleanQuery, bookId)
          if (queryRef.current !== searchQuery || bookIdRef.current !== bookId) return
          setResults(
            ftsResults.map((r) => ({
              id: `fts-${r.chunkId}`,
              snippet: r.text,
              highlightedSnippet: r.snippet,
              pageNumber: r.pageNumber,
              mode: 'exact' as SearchMode
            }))
          )
```

Field rename summary: `r.id → r.chunkId`, `r.data → r.text`. The `r.snippet` field is preserved as-is (FTS5 highlighted excerpt).

- [ ] **Step 4: Migrate `runSemanticSearch`, eliminating the `messagesGetChunkPage` loop**

Replace lines 113-130 (the `getContextForQuery` call + `Promise.all(contextTexts.map(...))` block with `messagesGetChunkPage`) with:

```ts
        const chunks = await getRagService().searchSemantic(cleanQuery, bookId, 10)
        if (queryRef.current !== searchQuery || bookIdRef.current !== bookId) return

        const resultsWithPages: BookSearchResult[] = chunks.map((c) => ({
          id: `semantic-${c.chunkId}`,
          snippet: c.text.length > 200 ? c.text.slice(0, 200) + '...' : c.text,
          pageNumber: c.pageNumber,
          mode: 'semantic' as SearchMode
        }))

        setResults(resultsWithPages)
```

Notes:
- The new IDs use the real `chunkId` (stable per chunk) instead of the old `semantic-${i}` (index-based, unstable across reruns).
- `pageNumber` now comes directly from the chunk metadata — no more secondary IPC roundtrip.
- The truncation rule (`> 200 chars → slice(0, 200) + '...'`) is preserved from the old code.

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes. If the hook's result shape doesn't line up with `SemanticChunk` / `TextMatch`, write a thin mapper inline; do not change the service's return types.

- [ ] **Step 4: Run tests**

```bash
pnpm test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/hooks/useBookSearch.ts
git commit -m "refactor(rag): migrate useBookSearch to RAG service

Both semantic and FTS5 paths now use getRagService(). Result-shape
mapping preserved at the hook boundary."
```

---

## Task 12: Delete dead code

**Files:**
- Modify: `apps/rishi-electron/src/main/ipc/search.ts` (delete the `search:contextForQuery` handler block)
- Modify: `apps/rishi-electron/src/preload/index.ts` (delete `getContextForQuery` export)
- Modify: `apps/rishi-electron/src/preload/types.ts` (delete `getContextForQuery` field)
- Modify: `apps/rishi-electron/src/renderer/src/lib/api.ts` (delete `getContextForQuery` wrapper)

- [ ] **Step 1: Grep to confirm `getContextForQuery` has no remaining callers**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
grep -rn "getContextForQuery" src/
```

Expected: only matches in the four files listed in the Files block above (definitions, exports, types) — no callers in hooks, components, or modules.

If any caller is still found, return to the relevant migration task (9, 10, or 11) and finish migrating that caller before continuing.

- [ ] **Step 2: Delete the IPC handler in `src/main/ipc/search.ts`**

Remove the entire `ipcMain.handle('search:contextForQuery', ...)` block (the third handler in the file, spanning roughly lines 27-59). **Keep** the `search:text` and `search:textFromVectorId` handlers — those are still used by the service via its IPC adapter.

After deletion, the file should still register `search:text` and `search:textFromVectorId` and nothing else; it stays smaller but its remaining handlers are unchanged.

- [ ] **Step 3: Delete `getContextForQuery` from `src/preload/index.ts`**

Find the line that looks like:

```ts
getContextForQuery: (queryText: string, bookId: number, k: number) =>
  ipcRenderer.invoke('search:contextForQuery', queryText, bookId, k),
```

Delete it (including the trailing comma if it leaves a hanging one).

- [ ] **Step 4: Delete `getContextForQuery` from `src/preload/types.ts`**

Find and delete the line:

```ts
getContextForQuery: (queryText: string, bookId: number, k: number) => Promise<string[]>
```

- [ ] **Step 5: Delete `getContextForQuery` from `src/renderer/src/lib/api.ts`**

Find and delete the exported wrapper function `export async function getContextForQuery(...) { ... }` (or `export const getContextForQuery = ...`), and remove any related re-exports.

- [ ] **Step 6: Verify typecheck passes (catches any missed references)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes. If anything still references the deleted symbol, fix that reference (it should be a leftover from a migration task — go back and update it).

- [ ] **Step 7: Run the full test suite**

```bash
pnpm test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/main/ipc/search.ts apps/rishi-electron/src/preload/index.ts apps/rishi-electron/src/preload/types.ts apps/rishi-electron/src/renderer/src/lib/api.ts
git commit -m "refactor(rag): delete search:contextForQuery IPC and related shims

The renderer-side RAG service now orchestrates embed + vector search +
chunk resolution directly via the existing fine-grained IPC channels.
The bundled search:contextForQuery handler, its preload export, its
preload type, and the lib/api.ts wrapper are no longer used."
```

---

## Task 13: Final verification & PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, and tests across the app**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm test
```

Expected: all three pass. If any fail:
- Typecheck failures: missed import or type mismatch from migration — fix in a new commit.
- Lint failures: usually unused-import warnings from removed `getContextForQuery` / `searchBookText` imports — fix in a new commit.
- Test failures: investigate; do not silence.

- [ ] **Step 2: Sanity-check `services/index.ts` is the only wiring site**

```bash
grep -rn "createRagService" src/
```

Expected: matches only in `src/renderer/src/services/rag/service.ts` (definition), `src/renderer/src/services/rag/index.ts` (re-export), `src/renderer/src/services/index.ts` (wiring), and `src/renderer/src/services/rag/service.test.ts` (test usage). No other call sites.

- [ ] **Step 3: Push the branch and open the PR**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git push -u origin refactor/rag-service
gh pr create --title "refactor(rag): unify retrieval behind a renderer-side RAG service" --body "$(cat <<'EOF'
## Summary
- New \`RagService\` at \`apps/rishi-electron/src/renderer/src/services/rag/\` unifies semantic + FTS5 retrieval behind 3 methods: \`searchSemantic\`, \`searchText\`, \`isIndexed\`.
- Three callers migrated: \`useChat\`, \`buildRealtimeAgent\`, \`useBookSearch\`. The secondary \`messagesGetChunkPage\` loop in \`useChat\` is gone — \`pageNumber\` arrives with the chunk.
- The bundled \`search:contextForQuery\` IPC handler is deleted; the renderer service orchestrates via the existing fine-grained IPC channels.
- 8 boundary tests using vi.fn() spy adapters; no Electron / sqlite / vector DB required at test time.
- TDD throughout — red → green → commit per behavior.

Spec: \`docs/superpowers/specs/2026-05-11-rag-service-design.md\`
Meta-spec: \`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md\` (Wave 1, service 1 of 6)

Depends on: PR for vector index naming bug fix (must merge first).

## Test plan
- [ ] \`pnpm typecheck\` clean
- [ ] \`pnpm lint\` clean
- [ ] \`pnpm test\` — all 8 new RAG service tests pass, no regressions
- [ ] Manual: open a book, send a chat message, verify response uses RAG context and source chunks show correct page numbers
- [ ] Manual: start voice chat, ask a book-specific question, verify the realtime agent retrieves context
- [ ] Manual: open the in-book search, run a semantic query and a text query, verify both return reasonable results
- [ ] Manual: open an unindexed book; verify chat / search gracefully shows no-context rather than crashing
EOF
)"
```

---

## Summary

After all tasks complete:
- 13 commits on `refactor/rag-service` branch.
- 1 separate prerequisite PR on `fix/vector-index-naming` (Task 0) — must merge first.
- Net diff (approximate): +400 lines added (service + tests + wiring), -150 lines removed (deletions + caller cleanups).
- All 6 boundary tests in the spec (split into 8 `it()` blocks for clarity) are green at the public interface.
- No tests poke service internals.
- Old shallow files are deleted, not retained as shims.
- Public interface of the service exactly matches the spec.
