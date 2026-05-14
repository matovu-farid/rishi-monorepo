import { eq, and } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { bookmarks } from '../database/schema.js'
import { handle } from '../../preload/ipc-contract.js'

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
  handle('bookmarks:list', (_event, bookId) => {
    const db = getDrizzle()
    return db
      .select()
      .from(bookmarks)
      .where(and(eq(bookmarks.bookId, bookId), eq(bookmarks.isDeleted, 0)))
      .orderBy(bookmarks.createdAt)
      .all()
  })

  handle('bookmarks:save', async (_event, params) => {
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
  })

  handle('bookmarks:delete', async (_event, bookmarkId) => {
    const db = getDrizzle()
    await db
      .update(bookmarks)
      .set({ isDeleted: 1, isDirty: 1, updatedAt: Date.now() })
      .where(eq(bookmarks.id, bookmarkId))
  })
}
