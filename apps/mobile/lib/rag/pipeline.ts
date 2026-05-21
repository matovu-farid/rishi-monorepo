import { getChunks } from './chunker'
import { embedBatch, isEmbeddingReady } from './embedder'
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
  return embedTextsOnServer(texts)
}

export async function embedBook(
  bookId: string,
  filePath: string,
  format: string,
  onProgress?: (progress: number) => void
): Promise<void> {
  // Skip if already embedded
  if (isBookEmbedded(bookId)) {
    onProgress?.(1)
    return
  }

  // 1. Extract text and chunk
  // bookId is passed so chunk IDs are deterministic across imports/platforms
  // (see lib/rag/chunker.ts -> chunkIdFor()).
  const chunks = await getChunks(filePath, format, bookId)
  if (chunks.length === 0) {
    onProgress?.(1)
    return
  }

  // 2. Embed in batches to manage memory
  for (let i = 0; i < chunks.length; i += BATCH_SIZE) {
    const batch = chunks.slice(i, i + BATCH_SIZE)
    const embeddings = await embedBatchWithFallback(batch.map(c => c.text))

    // 3. Store each chunk with its vector
    for (let j = 0; j < batch.length; j++) {
      const chunk = batch[j]
      const embedding = embeddings[j]
      // Guard against embedder backends that return fewer vectors than
      // requested (server truncation, partial on-device failure). Without
      // this check, sqlite-vec sees `JSON.stringify(undefined)` -> undefined
      // and rejects the bind with an opaque "wrong number of bindings"
      // error that leaves the book in a half-indexed state.
      if (!Array.isArray(embedding) || embedding.length === 0) {
        console.warn(
          `[pipeline] Skipping chunk ${chunk.id}: missing or empty embedding (got ${typeof embedding})`
        )
        continue
      }
      insertChunkWithVector(
        chunk.id,
        bookId,
        chunk.chunkIndex,
        chunk.text,
        chunk.chapter,
        embedding
      )
    }

    // Report progress
    onProgress?.(Math.min((i + BATCH_SIZE) / chunks.length, 1))

    // Small delay between batches to reduce memory pressure
    if (i + BATCH_SIZE < chunks.length) {
      await new Promise(r => setTimeout(r, BATCH_DELAY_MS))
    }
  }

  onProgress?.(1)
}

export async function reembedBook(
  bookId: string,
  filePath: string,
  format: string,
  onProgress?: (progress: number) => void
): Promise<void> {
  deleteBookChunks(bookId)
  await embedBook(bookId, filePath, format, onProgress)
}
