import {
  getAllBooks,
  getBook,
  saveBook,
  deleteBook,
  deleteChunksByBookId,
  updateBookCover,
  updateBookLocation,
  hasSavedEpubData,
  getBookOutline
} from '../database/queries.js'
import { deleteIndex } from '../vectordb/index.js'
import { handle } from '../../preload/ipc-contract.js'
import { errorMessage } from '../utils/errors.js'

export function registerBookHandlers(): void {
  handle('books:getAll', () => {
    try {
      return getAllBooks()
    } catch (error) {
      throw new Error(`Failed to get all books: ${errorMessage(error)}`)
    }
  })

  handle('books:get', (_event, bookId) => {
    try {
      return getBook(bookId) ?? null
    } catch (error) {
      throw new Error(`Failed to get book ${bookId}: ${errorMessage(error)}`)
    }
  })

  handle('books:save', (_event, book) => {
    try {
      return saveBook(book)
    } catch (error) {
      throw new Error(`Failed to save book: ${errorMessage(error)}`)
    }
  })

  handle('books:delete', (_event, bookId) => {
    try {
      // Hard-delete local-only artifacts (chunks + HNSW index) BEFORE the
      // soft-delete on `books`. The books row stays (is_deleted=1, is_dirty=1)
      // so the sync engine can propagate the deletion to the cloud; the
      // chunks + vector file are local and not sync-tracked, so safe to drop.
      // Order matters: indexer keeps a Map<name, Index> in memory, so we
      // remove that cache entry alongside the file via deleteIndex.
      deleteChunksByBookId(bookId)
      deleteIndex(`${bookId}-vectordb`)
      return void deleteBook(bookId)
    } catch (error) {
      throw new Error(`Failed to delete book ${bookId}: ${errorMessage(error)}`)
    }
  })

  handle('books:updateCover', (_event, bookId, cover) => {
    try {
      return void updateBookCover(bookId, cover)
    } catch (error) {
      throw new Error(`Failed to update cover for book ${bookId}: ${errorMessage(error)}`)
    }
  })

  handle('books:updateLocation', (_event, bookId, location) => {
    try {
      return void updateBookLocation(bookId, location)
    } catch (error) {
      throw new Error(`Failed to update location for book ${bookId}: ${errorMessage(error)}`)
    }
  })

  handle('books:hasSavedEpubData', (_event, bookId) => {
    try {
      return hasSavedEpubData(bookId)
    } catch (error) {
      throw new Error(`Failed to check epub data for book ${bookId}: ${errorMessage(error)}`)
    }
  })

  handle('books:getOutline', (_event, bookId) => {
    try {
      return getBookOutline(bookId)
    } catch (error) {
      throw new Error(`Failed to get book outline: ${errorMessage(error)}`)
    }
  })
}
