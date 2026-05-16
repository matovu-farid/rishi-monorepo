import { searchBookText, getTextFromVectorId } from '../database/queries.js'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

export function registerSearchHandlers(): void {
  handle('search:text', (_event, query, bookId) => {
    try {
      return searchBookText(query, bookId)
    } catch (error) {
      throw new Error(`Failed to search text: ${errorMessage(error)}`)
    }
  })

  handle('search:textFromVectorId', (_event, vectorId) => {
    try {
      return getTextFromVectorId(vectorId)
    } catch (error) {
      throw new Error(`Failed to get text from vector ID ${vectorId}: ${errorMessage(error)}`)
    }
  })
}
