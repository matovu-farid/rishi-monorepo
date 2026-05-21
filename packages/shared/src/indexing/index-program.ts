/**
 * Indexing pipeline (Effect-based).
 *
 * Ported from `apps/rishi-electron/src/renderer/src/services/indexing/
 * index-program.ts`. The original is already a pure Effect/TS program — no
 * Node-only imports — so this copy is byte-identical apart from being in the
 * shared package.
 *
 * Mobile (Batch 2A) wires it up via `@rishi/shared/indexing/index-program`
 * so chunk IDs match electron exactly. The dependency `effect` is declared
 * as an OPTIONAL peer of @rishi/shared so consumers that don't need this
 * module aren't forced to install Effect.
 */

import { Effect, Stream } from 'effect'

export interface IndexChunk {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

export interface ProcessJobItem {
  id: number
  text: string
}

export interface IndexBookDeps {
  bookId: number
  numPages: number
  extract: (pageNumber: number) => Promise<string[]>
  saveChunks: (chunks: IndexChunk[]) => Promise<void>
  processJob: (pageNumber: number, items: ProcessJobItem[]) => Promise<void>
  concurrency?: number
  /**
   * Page to index first. The pipeline indexes this page before any other so
   * features that depend on the vector index (chat/RAG) work for the user's
   * current location as soon as possible. Remaining pages are indexed in
   * expanding-outward order from startPage. Defaults to 1.
   */
  startPage?: number
  /**
   * Pages already present in chunk_data + the vector index. These are filtered
   * out of the schedule so we don't redo extraction or embedding for them.
   */
  skipPages?: ReadonlySet<number>
  onAdvance?: () => void
  onFinish?: () => void
  onError?: (message: string) => void
}

/**
 * Return [center, center-1, center+1, center-2, center+2, ...] clamped to
 * [1, total]. Used to schedule pages so the user's current location is
 * indexed first and nearby pages are indexed before distant ones.
 */
const pagesAroundCenter = (centerRaw: number, total: number): number[] => {
  if (total <= 0) return []
  const center = Math.min(Math.max(Math.trunc(centerRaw) || 1, 1), total)
  const out: number[] = [center]
  let offset = 1
  while (out.length < total) {
    const left = center - offset
    const right = center + offset
    if (left >= 1) out.push(left)
    if (right <= total && out.length < total) out.push(right)
    offset++
  }
  return out
}

/**
 * Deterministic ID formula preserved from the legacy renderer pipeline
 * (background-page.tsx). chunk_data uses INSERT OR IGNORE keyed on this id,
 * and HNSW vector labels must match, so the formula MUST stay stable.
 *
 * Same formula is reproduced in the mobile chunker so PDF chunk IDs match
 * across electron and mobile for the same (bookId, pageNumber, paragraph).
 */
export const chunkId = (pageNumber: number, bookId: number, index: number): number =>
  pageNumber * 1_000_000 + bookId * 10_000 + index

export const indexBookProgram = (deps: IndexBookDeps): Effect.Effect<void, Error> => {
  const concurrency = deps.concurrency ?? 4

  const processPage = (pageNumber: number): Effect.Effect<void, Error> =>
    Effect.gen(function* () {
      const paragraphs = yield* Effect.tryPromise({
        try: () => deps.extract(pageNumber),
        catch: (e) =>
          new Error(
            `extract failed on page ${pageNumber}: ${e instanceof Error ? e.message : String(e)}`
          )
      })

      if (paragraphs.length === 0) {
        if (deps.onAdvance) deps.onAdvance()
        return
      }

      const chunks: IndexChunk[] = paragraphs.map((data, index) => ({
        id: chunkId(pageNumber, deps.bookId, index),
        pageNumber,
        bookId: deps.bookId,
        data
      }))

      yield* Effect.tryPromise({
        try: () => deps.saveChunks(chunks),
        catch: (e) =>
          new Error(
            `saveChunks failed on page ${pageNumber}: ${e instanceof Error ? e.message : String(e)}`
          )
      })

      const items: ProcessJobItem[] = chunks.map((c) => ({ id: c.id, text: c.data }))
      yield* Effect.tryPromise({
        try: () => deps.processJob(pageNumber, items),
        catch: (e) =>
          new Error(
            `processJob failed on page ${pageNumber}: ${e instanceof Error ? e.message : String(e)}`
          )
      })

      if (deps.onAdvance) deps.onAdvance()
    })

  const skip = deps.skipPages ?? new Set<number>()
  const ordered = pagesAroundCenter(deps.startPage ?? 1, deps.numPages).filter((p) => !skip.has(p))
  const [priority, ...rest] = ordered as [number | undefined, ...number[]]

  const program = Effect.gen(function* () {
    if (priority !== undefined) {
      yield* processPage(priority)
    }
    if (rest.length > 0) {
      yield* Stream.runDrain(
        Stream.fromIterable(rest).pipe(Stream.mapEffect(processPage, { concurrency }))
      )
    }
  })

  return program.pipe(
    Effect.tap(() => Effect.sync(() => deps.onFinish?.())),
    Effect.tapError((err) =>
      Effect.sync(() => deps.onError?.(err instanceof Error ? err.message : String(err)))
    )
  )
}
