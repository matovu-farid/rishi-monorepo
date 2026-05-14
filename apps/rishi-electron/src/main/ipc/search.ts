import { searchBookText, getTextFromVectorId } from '../database/queries.js'
import { handle } from '../../preload/ipc-contract.js'

export function registerSearchHandlers(): void {
  handle('search:text', (_event, query, bookId) => {
    try {
      return searchBookText(query, bookId)
    } catch (error) {
      throw new Error(
        `Failed to search text: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  handle('search:textFromVectorId', (_event, vectorId) => {
    try {
      return getTextFromVectorId(vectorId)
    } catch (error) {
      throw new Error(
        `Failed to get text from vector ID ${vectorId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
