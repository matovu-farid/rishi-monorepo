import { ipcMain } from 'electron'
import { eq, and } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { bookmarks } from '../database/schema.js'

export interface BookmarkRow {
  id: string
  bookId: string
  location: string
  label: string
  pageNumber: number | null
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: number
  isDeleted: number
}

export function registerBookmarkHandlers(): void {
  ipcMain.handle('bookmarks:list', async (_event, bookId: string): Promise<BookmarkRow[]> => {
    const db = getDrizzle()
    return db
      .select()
      .from(bookmarks)
      .where(and(eq(bookmarks.bookId, bookId), eq(bookmarks.isDeleted, 0)))
      .orderBy(bookmarks.createdAt)
      .all()
  })

  ipcMain.handle(
    'bookmarks:save',
    async (
      _event,
      params: { id: string; bookId: string; location: string; label: string }
    ): Promise<void> => {
      const db = getDrizzle()
      const now = Date.now()
      await db.insert(bookmarks).values({
        id: params.id,
        bookId: params.bookId,
        location: params.location,
        label: params.label,
        createdAt: now,
        updatedAt: now,
        syncVersion: 0,
        isDirty: 1,
        isDeleted: 0
      })
    }
  )

  ipcMain.handle('bookmarks:delete', async (_event, bookmarkId: string): Promise<void> => {
    const db = getDrizzle()
    await db
      .update(bookmarks)
      .set({ isDeleted: 1, isDirty: 1, updatedAt: Date.now() })
      .where(eq(bookmarks.id, bookmarkId))
  })
}
