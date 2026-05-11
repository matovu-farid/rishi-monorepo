/**
 * Process EPUB paragraphs into page data chunks, save to DB, embed, and save vectors.
 * Ported from the Tauri version to use Electron's @/lib/api functions.
 */

import { saveVectors, hasSavedEpubData, savePageDataMany, hasVectorsForBook } from '@/lib/api'
import type { EmbedParam, Vector, ChunkDataInsertable } from '@/lib/api'
import { embedWithFallback } from './embed-fallback'

export interface PageDataInsertable {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

function batchEmbed(embedParams: EmbedParam[]): EmbedParam[][] {
  const batchSize = 2
  const batches: EmbedParam[][] = []
  for (let i = 0; i < embedParams.length; i += batchSize) {
    batches.push(embedParams.slice(i, i + batchSize))
  }
  return batches
}

export async function processEpubJob(bookId: number, pageData: PageDataInsertable[]) {
  try {
    if (pageData.length === 0) return

    const chunksExist = await hasSavedEpubData({ bookId })
    const vectorsExist = await hasVectorsForBook(bookId)

    if (chunksExist && vectorsExist) return // fully indexed, nothing to do

    if (!chunksExist) {
      // Convert to ChunkDataInsertable for savePageDataMany
      const chunkData: ChunkDataInsertable[] = pageData.map((item) => ({
        id: item.id,
        pageNumber: item.pageNumber,
        bookId: item.bookId,
        data: item.data
      }))
      // Save page data first so it is persisted even if embedding later fails
      await savePageDataMany({ pageData: chunkData })
    }

    // Embedding/vector save is best-effort.
    // Runs when chunks were just saved OR when chunks exist but vectors are missing
    // (recovery from a previously failed embedding step).
    const embedParams: EmbedParam[] = pageData.map((item) => ({
      text: item.data,
      metadata: {
        id: item.id,
        pageNumber: item.pageNumber,
        bookId
      }
    }))

    try {
      const batches = batchEmbed(embedParams)
      for (const batch of batches) {
        const embedResults = await embedWithFallback(batch)

        const vectorObjects = embedResults.map((result) => ({
          id: result.metadata.id,
          vector: result.embedding,
          text: result.text,
          metadata: result.metadata
        }))
        const vectors: Vector[] = vectorObjects.map((v) => ({
          id: v.id,
          vector: v.vector
        }))

        if (vectorObjects.length > 0) {
          await saveVectors({
            name: `${bookId}-vectordb`,
            dim: vectorObjects[0].vector.length,
            vectors
          })
        }
      }
    } catch (embedError) {
      console.error('[epub] embedding/vector save failed, will retry on next open:', embedError)
      // Don't re-throw -- page data is saved, vectors can be retried
    }
  } catch (error) {
    console.error('>>> Error in processEpubJob:', error)
    throw error
  }
}
