import type { EmbedParam, EmbedResult, ChunkDataInsertable } from '@/lib/api'
import type { RagService } from '../rag'
import type { BookStoreIpc, ImportProgressEvent, PageDataInsertable } from './types'

export interface IndexerDeps {
  db: BookStoreIpc
  rag: RagService
  embed: (params: EmbedParam[]) => Promise<EmbedResult[]>
  embedBatchSize: number
}

function chunkArray<T>(array: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < array.length; i += size) out.push(array.slice(i, i + size))
  return out
}

/**
 * RAG-indexing recovery pipeline. Replaces process_epub.ts.
 *
 * - Skip entirely if chunks AND vectors exist.
 * - If chunks missing: save chunks, then embed + save vectors.
 * - If chunks exist but vectors missing (regression caught in e44ab1b9):
 *   skip chunk save, only embed + save vectors.
 * - Embed failure is swallowed (best-effort, matches today's processEpubJob).
 */
export async function indexBook(
  deps: IndexerDeps,
  bookId: number,
  pageDataOpt: PageDataInsertable[] | undefined,
  progressEmit: (event: ImportProgressEvent) => void
): Promise<void> {
  const [chunksExist, vectorsExist] = await Promise.all([
    deps.db.hasSavedEpubData(bookId),
    deps.rag.isIndexed(bookId)
  ])
  if (chunksExist && vectorsExist) return

  // Resolve pageData: caller-provided wins; else read from DB if chunks exist.
  let pageData: PageDataInsertable[]
  if (pageDataOpt !== undefined) {
    pageData = pageDataOpt
  } else if (chunksExist) {
    const rows = await deps.db.getAllPageDataByBookId(bookId)
    pageData = rows.map((p) => ({
      id: p.id,
      pageNumber: p.pageNumber,
      bookId: p.bookId,
      data: p.data
    }))
  } else {
    pageData = []
  }
  if (pageData.length === 0) return

  if (!chunksExist) {
    progressEmit({ kind: 'indexing', bookId, reason: 'chunks-missing' })
    const chunks: ChunkDataInsertable[] = pageData.map((p) => ({
      id: p.id,
      pageNumber: p.pageNumber,
      bookId: p.bookId,
      data: p.data
    }))
    await deps.db.savePageDataMany(chunks)
  } else {
    progressEmit({ kind: 'indexing', bookId, reason: 'vectors-missing' })
  }

  // Embed + save vectors. Best-effort: swallow failures so page data stays.
  let ok = true
  try {
    const embedParams: EmbedParam[] = pageData.map((p) => ({
      text: p.data,
      metadata: { id: p.id, pageNumber: p.pageNumber, bookId }
    }))
    for (const batch of chunkArray(embedParams, deps.embedBatchSize)) {
      const results = await deps.embed(batch)
      const vectors = results.map((r) => ({ id: r.metadata.id, vector: r.embedding }))
      if (vectors.length > 0) {
        await deps.db.saveVectors(`${bookId}-vectordb`, results[0].embedding.length, vectors)
      }
    }
  } catch (err) {
    ok = false
    console.error('[book-import] embedding/vector save failed, will retry on next open:', err)
  }
  progressEmit({ kind: 'indexed', bookId, ok })
}
