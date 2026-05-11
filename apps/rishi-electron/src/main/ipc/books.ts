import { ipcMain } from 'electron'
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

export function registerBookHandlers(): void {
  ipcMain.handle('books:getAll', async () => {
    try {
      return await getAllBooks()
    } catch (error) {
      throw new Error(
        `Failed to get all books: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:get', async (_event, bookId: number) => {
    try {
      return await getBook(bookId)
    } catch (error) {
      throw new Error(
        `Failed to get book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:save', async (_event, book: unknown) => {
    try {
      return await saveBook(book)
    } catch (error) {
      throw new Error(
        `Failed to save book: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:delete', async (_event, bookId: number) => {
    try {
      // Hard-delete local-only artifacts (chunks + HNSW index) BEFORE the
      // soft-delete on `books`. The books row stays (is_deleted=1, is_dirty=1)
      // so the sync engine can propagate the deletion to the cloud; the
      // chunks + vector file are local and not sync-tracked, so safe to drop.
      // Order matters: indexer keeps a Map<name, Index> in memory, so we
      // remove that cache entry alongside the file via deleteIndex.
      deleteChunksByBookId(bookId)
      await deleteIndex(`${bookId}-vectordb`)
      return await deleteBook(bookId)
    } catch (error) {
      throw new Error(
        `Failed to delete book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:updateCover', async (_event, bookId: number, cover: number[]) => {
    try {
      return await updateBookCover(bookId, cover)
    } catch (error) {
      throw new Error(
        `Failed to update cover for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:updateLocation', async (_event, bookId: number, location: string) => {
    try {
      return await updateBookLocation(bookId, location)
    } catch (error) {
      throw new Error(
        `Failed to update location for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:hasSavedEpubData', async (_event, bookId: number) => {
    try {
      return await hasSavedEpubData(bookId)
    } catch (error) {
      throw new Error(
        `Failed to check epub data for book ${bookId}: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('books:getOutline', async (_event, bookId: number) => {
    try {
      return await getBookOutline(bookId)
    } catch (error) {
      throw new Error(
        `Failed to get book outline: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
