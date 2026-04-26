import { ipcMain } from 'electron'
import { eq, and } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { highlights } from '../database/schema.js'

export function registerHighlightHandlers(): void {
  ipcMain.handle('highlights:list', async (_event, bookId: string) => {
    const db = getDrizzle()
    return db
      .select()
      .from(highlights)
      .where(and(eq(highlights.bookId, bookId), eq(highlights.isDeleted, 0)))
      .all()
  })

  ipcMain.handle(
    'highlights:save',
    async (
      _event,
      params: {
        bookSyncId: string
        cfiRange: string
        text: string
        color?: string
        note?: string
        chapter?: string
      }
    ): Promise<string> => {
      const db = getDrizzle()
      const now = Date.now()

      // Check if a highlight already exists for this cfiRange + book (non-deleted)
      const existing = await db
        .select({ id: highlights.id })
        .from(highlights)
        .where(
          and(
            eq(highlights.bookId, params.bookSyncId),
            eq(highlights.cfiRange, params.cfiRange),
            eq(highlights.isDeleted, 0)
          )
        )
        .limit(1)
        .all()

      if (existing.length > 0) {
        // Update existing highlight
        await db
          .update(highlights)
          .set({
            text: params.text,
            color: params.color ?? 'yellow',
            note: params.note ?? '',
            chapter: params.chapter ?? null,
            updatedAt: now,
            isDirty: 1
          })
          .where(eq(highlights.id, existing[0].id))
        return existing[0].id
      }

      // Insert new highlight
      const id = crypto.randomUUID()
      await db.insert(highlights).values({
        id,
        bookId: params.bookSyncId,
        cfiRange: params.cfiRange,
        text: params.text,
        color: params.color ?? 'yellow',
        note: params.note ?? '',
        chapter: params.chapter ?? null,
        createdAt: String(now),
        updatedAt: now,
        syncVersion: 0,
        isDirty: 1,
        isDeleted: 0
      })

      return id
    }
  )

  ipcMain.handle(
    'highlights:delete',
    async (_event, bookSyncId: string, cfiRange: string): Promise<void> => {
      const db = getDrizzle()
      await db
        .update(highlights)
        .set({ isDeleted: 1, isDirty: 1, updatedAt: Date.now() })
        .where(and(eq(highlights.bookId, bookSyncId), eq(highlights.cfiRange, cfiRange)))
    }
  )

  ipcMain.handle('highlights:deleteById', async (_event, highlightId: string): Promise<void> => {
    const db = getDrizzle()
    await db
      .update(highlights)
      .set({ isDeleted: 1, isDirty: 1, updatedAt: Date.now() })
      .where(eq(highlights.id, highlightId))
  })

  ipcMain.handle(
    'highlights:updateNote',
    async (_event, highlightId: string, note: string): Promise<void> => {
      const db = getDrizzle()
      await db
        .update(highlights)
        .set({ note, updatedAt: Date.now(), isDirty: 1 })
        .where(eq(highlights.id, highlightId))
    }
  )

  ipcMain.handle(
    'highlights:updateColor',
    async (_event, highlightId: string, color: string): Promise<void> => {
      const db = getDrizzle()
      await db
        .update(highlights)
        .set({ color, updatedAt: Date.now(), isDirty: 1 })
        .where(eq(highlights.id, highlightId))
    }
  )
}
