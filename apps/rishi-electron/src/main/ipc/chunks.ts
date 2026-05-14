import {
  savePageDataMany,
  getAllPageDataByBookId,
  getIndexedPageNumbers
} from '../database/queries.js'
import { handle } from '../../preload/ipc-contract.js'

export function registerChunkHandlers(): void {
  handle('chunks:saveMany', (_event, pageData) => {
    try {
      return void savePageDataMany(pageData)
    } catch (error) {
      throw new Error(
        `Failed to save page data: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('chunks:getByBookId', (_event, bookId) => {
    try {
      return getAllPageDataByBookId(bookId)
    } catch (error) {
      throw new Error(
        `Failed to get page data for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('chunks:getIndexedPages', (_event, bookId) => {
    try {
      return getIndexedPageNumbers(bookId)
    } catch (error) {
      throw new Error(
        `Failed to get indexed pages for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
