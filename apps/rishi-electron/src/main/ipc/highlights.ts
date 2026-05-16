import { eq, and } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { highlights } from '../database/schema.js'
import { handle } from '../../preload/ipc-contract.js'
import { defaultSyncFields, softDeleteFields } from './_syncFields.js'

export function registerHighlightHandlers(): void {
  handle('highlights:list', (_event, bookId) => {
    const db = getDrizzle()
    return db
      .select()
      .from(highlights)
      .where(and(eq(highlights.bookId, bookId), eq(highlights.isDeleted, 0)))
      .all()
  })

  handle('highlights:save', async (_event, params) => {
    const db = getDrizzle()
    const now = Date.now()

    // Check if a highlight already exists for this cfiRange + book (non-deleted)
    const existing = db
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
      ...defaultSyncFields
    })

    return id
  })

  handle('highlights:delete', async (_event, bookSyncId, cfiRange) => {
    const db = getDrizzle()
    await db
      .update(highlights)
      .set(softDeleteFields())
      .where(and(eq(highlights.bookId, bookSyncId), eq(highlights.cfiRange, cfiRange)))
  })

  handle('highlights:deleteById', async (_event, highlightId) => {
    const db = getDrizzle()
    await db.update(highlights).set(softDeleteFields()).where(eq(highlights.id, highlightId))
  })

  handle('highlights:updateNote', async (_event, highlightId, note) => {
    const db = getDrizzle()
    await db
      .update(highlights)
      .set({ note, updatedAt: Date.now(), isDirty: 1 })
      .where(eq(highlights.id, highlightId))
  })

  handle('highlights:updateColor', async (_event, highlightId, color) => {
    const db = getDrizzle()
    await db
      .update(highlights)
      .set({ color, updatedAt: Date.now(), isDirty: 1 })
      .where(eq(highlights.id, highlightId))
  })
}
