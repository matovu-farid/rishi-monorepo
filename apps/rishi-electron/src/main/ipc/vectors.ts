import { ipcMain } from 'electron'
import {
  generateEmbeddings,
  saveVectors as vectorSave,
  searchVectors as vectorSearch,
  hasVectorsForBook as vectorsHasFor
} from '../vectordb/index.js'

export function registerVectorHandlers(): void {
  ipcMain.handle('vectors:embed', async (_event, params: unknown[]) => {
    try {
      return await generateEmbeddings(
        params as Array<{
          text: string
          metadata: { id: number; pageNumber: number; bookId: number }
        }>
      )
    } catch (error) {
      throw new Error(`Failed to embed: ${error instanceof Error ? error.message : String(error)}`)
    }
  })

  ipcMain.handle(
    'vectors:save',
    async (_event, name: string, dim: number, vectors: Array<{ id: number; vector: number[] }>) => {
      try {
        return await vectorSave(name, dim, vectors)
      } catch (error) {
        throw new Error(
          `Failed to save vectors for ${name}: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )

  ipcMain.handle(
    'vectors:search',
    async (_event, name: string, query: number[], dim: number, k: number) => {
      try {
        return await vectorSearch(name, query, dim, k)
      } catch (error) {
        throw new Error(
          `Failed to search vectors for ${name}: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )

  ipcMain.handle('vectors:hasFor', async (_event, bookId: number) => {
    try {
      return vectorsHasFor(bookId)
    } catch {
      return false
    }
  })

  ipcMain.handle(
    'vectors:processJob',
    async (
      _event,
      _pageNumber: number,
      bookId: number,
      pageData: Array<{ text: string; id: number }>
    ) => {
      if (pageData.length === 0) return

      try {
        const embedInput = pageData.map((item) => ({
          text: item.text,
          metadata: { id: item.id, pageNumber: _pageNumber, bookId }
        }))

        const BATCH_SIZE = 32
        for (let i = 0; i < embedInput.length; i += BATCH_SIZE) {
          const batch = embedInput.slice(i, i + BATCH_SIZE)
          const embedResults = await generateEmbeddings(batch)

          if (embedResults.length > 0) {
            const vectors = embedResults.map((r) => ({
              id: r.metadata.id,
              vector: r.embedding
            }))
            await vectorSave(`${bookId}-vectordb`, embedResults[0].dim, vectors)
          }
        }
      } catch (error) {
        throw new Error(
          `Failed to process job for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )
}
