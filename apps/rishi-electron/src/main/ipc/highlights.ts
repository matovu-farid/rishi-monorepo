import { eq, and } from 'drizzle-orm'
import { getDrizzle } from '../database/drizzle.js'
import { highlights } from '../database/schema.js'
import { handle } from '../../preload/ipc-contract.js'
import { defaultSyncFields, softDeleteFields } from './_syncFields.js'

export function registerHighlightHandlers(): void {
  handle('highlights:list', (_event, bookId) => {
    const db = getDrizzle()
    const rows = db
      .select()
      .from(highlights)
      .where(and(eq(highlights.bookId, bookId), eq(highlights.isDeleted, 0)))
      .all()

    // Map on-disk rows to the renderer-facing HighlightRow shape:
    // - format is NOT NULL with a default of 'epub' at the column level, so
    //   legacy rows already read back as 'epub' from drizzle — no fallback needed.
    // - cfi_range '' (written by PDF rows to satisfy NOT NULL) becomes null
    // - locator passes through as-is (null for EPUB rows)
    return rows.map((row) => ({
      ...row,
      format: row.format as 'epub' | 'pdf',
      cfiRange: row.cfiRange === '' ? null : row.cfiRange,
      locator: row.locator ?? null
    }))
  })

  handle('highlights:save', async (_event, params) => {
    const db = getDrizzle()
    const now = Date.now()
    const format = params.format ?? 'epub'

    // For PDF rows, always insert fresh (locator JSON encodes position uniquely
    // and is not a stable upsert key at this stage).
    if (format === 'pdf') {
      const id = crypto.randomUUID()
      await db.insert(highlights).values({
        id,
        bookId: params.bookSyncId,
        format,
        cfiRange: '',
        locator: params.locator ?? null,
        text: params.text,
        color: params.color ?? 'yellow',
        note: params.note ?? '',
        chapter: params.chapter ?? null,
        createdAt: String(now),
        updatedAt: now,
        ...defaultSyncFields
      })
      return id
    }

    // EPUB path: upsert by (bookId, cfi_range).
    const cfiRange = params.cfiRange ?? ''
    const existing = db
      .select({ id: highlights.id })
      .from(highlights)
      .where(
        and(
          eq(highlights.bookId, params.bookSyncId),
          eq(highlights.cfiRange, cfiRange),
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

    // Insert new EPUB highlight
    const id = crypto.randomUUID()
    await db.insert(highlights).values({
      id,
      bookId: params.bookSyncId,
      format,
      cfiRange,
      locator: null,
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

  // EPUB-only delete channel: the format guard is intentional.
  // PDF rows all share cfi_range='' so matching on cfiRange alone would
  // mass-delete all PDF highlights for a book. PDF deletion must go through
  // highlights:deleteById which targets a specific row by primary key.
  handle('highlights:delete', async (_event, bookSyncId, cfiRange) => {
    const db = getDrizzle()
    await db
      .update(highlights)
      .set(softDeleteFields())
      .where(
        and(
          eq(highlights.bookId, bookSyncId),
          eq(highlights.cfiRange, cfiRange),
          eq(highlights.format, 'epub')
        )
      )
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
