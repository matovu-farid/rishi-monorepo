import { ipcMain } from 'electron'
import { searchBookText, getTextFromVectorId } from '../database/queries.js'

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
}
