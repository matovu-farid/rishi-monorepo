import { ipcMain } from 'electron'
import { eq } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { books } from '../database/schema.js'

export function registerBooksExtraHandlers(): void {
  ipcMain.handle('books:getSyncId', async (_event, bookId: number) => {
    const db = getDrizzle()
    const rows = await db.select({ syncId: books.syncId }).from(books).where(eq(books.id, bookId))
    return rows[0]?.syncId ?? null
  })

  ipcMain.handle('books:updateFilepath', async (_event, bookId: number, filepath: string) => {
    const db = getDrizzle()
    await db.update(books).set({ filepath }).where(eq(books.id, bookId))
  })

  ipcMain.handle(
    'books:updateFileHash',
    async (_event, bookId: number, fileHash: string, fileR2Key: string) => {
      const db = getDrizzle()
      await db.update(books).set({ fileHash, fileR2Key, isDirty: 1 }).where(eq(books.id, bookId))
    }
  )
}
