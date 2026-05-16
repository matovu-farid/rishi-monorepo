import {
  generateEmbeddings,
  saveVectors as vectorSave,
  searchVectors as vectorSearch,
  hasVectorsForBook as vectorsHasFor
} from '../vectordb/index.js'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

export function registerVectorHandlers(): void {
  handle('vectors:embed', async (_event, params) => {
    try {
      return await generateEmbeddings(params)
    } catch (error) {
      throw new Error(`Failed to embed: ${errorMessage(error)}`)
    }
  })

  handle('vectors:save', (_event, name, dim, vectors) => {
    try {
      return void vectorSave(name, dim, vectors)
    } catch (error) {
      throw new Error(`Failed to save vectors for ${name}: ${errorMessage(error)}`)
    }
  })

  handle('vectors:search', (_event, name, query, dim, k) => {
    try {
      return vectorSearch(name, query, dim, k)
    } catch (error) {
      throw new Error(`Failed to search vectors for ${name}: ${errorMessage(error)}`)
    }
  })

  handle('vectors:hasFor', (_event, bookId) => {
    try {
      return vectorsHasFor(bookId)
    } catch {
      return false
    }
  })

  handle('vectors:processJob', async (_event, pageNumber, bookId, pageData) => {
    if (pageData.length === 0) return

    try {
      const embedInput = pageData.map((item) => ({
        text: item.text,
        metadata: { id: item.id, pageNumber, bookId }
      }))

      const BATCH_SIZE = 32
      for (let i = 0; i < embedInput.length; i += BATCH_SIZE) {
        const batch = embedInput.slice(i, i + BATCH_SIZE)
        // eslint-disable-next-line no-await-in-loop -- Backpressure: embedding model is CPU/GPU bound; running batches in parallel would oversubscribe and increase per-batch latency without throughput gain.
        const embedResults = await generateEmbeddings(batch)

        if (embedResults.length > 0) {
          const vectors = embedResults.map((r) => ({
            id: r.metadata.id,
            vector: r.embedding
          }))
          vectorSave(`${bookId}-vectordb`, embedResults[0].dim, vectors)
        }
      }
    } catch (error) {
      throw new Error(`Failed to process job for book ${bookId}: ${errorMessage(error)}`)
    }
  })
}
