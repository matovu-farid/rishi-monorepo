import { ipcMain } from 'electron'
import { searchBookText, getTextFromVectorId } from '../database/queries.js'
import { embedText } from '../vectordb/index.js'
import { searchVectors } from '../vectordb/index.js'

export function registerSearchHandlers(): void {
  ipcMain.handle('search:text', async (_event, query: string, bookId: number) => {
    try {
      return await searchBookText(query, bookId)
    } catch (error) {
      throw new Error(
        `Failed to search text: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('search:textFromVectorId', async (_event, vectorId: number) => {
    try {
      return await getTextFromVectorId(vectorId)
    } catch (error) {
      throw new Error(
        `Failed to get text from vector ID ${vectorId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle(
    'search:contextForQuery',
    async (_event, queryText: string, bookId: number, k: number) => {
      try {
        // 1. Embed the query text
        const embedding = await embedText(queryText)

        // 2. Search vectors for the book's index (uses book_ prefix to match processJob)
        const indexName = `book_${bookId}`
        const results = await searchVectors(indexName, embedding, embedding.length, k)

        // 3. Retrieve text for each matching vector
        const contextTexts: string[] = []
        for (const result of results) {
          try {
            const chunk = getTextFromVectorId(result.id)
            if (chunk) {
              contextTexts.push(chunk.data)
            }
          } catch {
            // Skip individual retrieval failures
          }
        }

        return contextTexts
      } catch (error) {
        throw new Error(
          `Failed to get context for query: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )
}
