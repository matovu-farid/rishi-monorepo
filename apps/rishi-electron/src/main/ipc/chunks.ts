import {
  savePageDataMany,
  getAllPageDataByBookId,
  getIndexedPageNumbers
} from '../database/queries.js'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

export function registerChunkHandlers(): void {
  handle('chunks:saveMany', (_event, pageData) => {
    try {
      return void savePageDataMany(pageData)
    } catch (error) {
      throw new Error(`Failed to save page data: ${errorMessage(error)}`)
    }
  })

  handle('chunks:getByBookId', (_event, bookId) => {
    try {
      return getAllPageDataByBookId(bookId)
    } catch (error) {
      throw new Error(`Failed to get page data for book ${bookId}: ${errorMessage(error)}`)
    }
  })

  handle('chunks:getIndexedPages', (_event, bookId) => {
    try {
      return getIndexedPageNumbers(bookId)
    } catch (error) {
      throw new Error(`Failed to get indexed pages for book ${bookId}: ${errorMessage(error)}`)
    }
  })
}
