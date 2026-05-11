import { ipcMain } from 'electron'
import {
  savePageDataMany,
  getAllPageDataByBookId,
  getIndexedPageNumbers
} from '../database/queries.js'

export function registerChunkHandlers(): void {
  ipcMain.handle('chunks:saveMany', async (_event, pageData: unknown[]) => {
    try {
      return await savePageDataMany(pageData)
    } catch (error) {
      throw new Error(
        `Failed to save page data: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('chunks:getByBookId', async (_event, bookId: number) => {
    try {
      return await getAllPageDataByBookId(bookId)
    } catch (error) {
      throw new Error(
        `Failed to get page data for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('chunks:getIndexedPages', (_event, bookId: number) => {
    try {
      return getIndexedPageNumbers(bookId)
    } catch (error) {
      throw new Error(
        `Failed to get indexed pages for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
