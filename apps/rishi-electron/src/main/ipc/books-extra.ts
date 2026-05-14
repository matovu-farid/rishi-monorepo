import { eq } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { books } from '../database/schema.js'
import { handle } from '../../preload/ipc-contract.js'

export function registerBooksExtraHandlers(): void {
  handle('books:getSyncId', async (_event, bookId) => {
    const db = getDrizzle()
    const rows = await db.select({ syncId: books.syncId }).from(books).where(eq(books.id, bookId))
    return rows[0]?.syncId ?? null
  })

  handle('books:updateFilepath', async (_event, bookId, filepath) => {
    const db = getDrizzle()
    await db.update(books).set({ filepath }).where(eq(books.id, bookId))
  })

  handle('books:updateFileHash', async (_event, bookId, fileHash, fileR2Key) => {
    const db = getDrizzle()
    await db.update(books).set({ fileHash, fileR2Key, isDirty: 1 }).where(eq(books.id, bookId))
  })
}
