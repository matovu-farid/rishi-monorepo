import * as Crypto from 'expo-crypto'
import { db } from '@/lib/db'
import { highlights } from '@rishi/shared/schema'
import { eq, and, desc } from 'drizzle-orm'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'
import type { Highlight, HighlightColor } from '@/types/highlight'

/**
 * Insert a new highlight for a book. Generates a UUID, sets timestamps,
 * marks as dirty for sync, and triggers a sync push.
 */
export function insertHighlight(params: {
  bookId: string
  cfiRange: string
  text: string
  color: HighlightColor
  note?: string | null
  chapter?: string | null
}): Highlight {
  const now = Date.now()
  const id = Crypto.randomUUID()

  db.insert(highlights)
    .values({
      id,
      bookId: params.bookId,
      cfiRange: params.cfiRange,
      text: params.text,
      color: params.color,
      note: params.note ?? null,
      chapter: params.chapter ?? null,
      createdAt: now,
      updatedAt: now,
      isDirty: true,
      isDeleted: false,
    })
    .run()

  triggerSyncOnWrite()

  return {
    id,
    bookId: params.bookId,
    cfiRange: params.cfiRange,
    text: params.text,
    color: params.color,
    note: params.note ?? null,
    chapter: params.chapter ?? null,
    createdAt: now,
    updatedAt: now,
  }
}

/**
 * Get all non-deleted highlights for a book, ordered by most recent first.
 */
export function getHighlightsByBookId(bookId: string): Highlight[] {
  const rows = db
    .select()
    .from(highlights)
    .where(and(eq(highlights.bookId, bookId), eq(highlights.isDeleted, false)))
    .orderBy(desc(highlights.createdAt))
    .all()

  return rows.map(mapRowToHighlight)
}

/**
 * Update a highlight's color and/or note. Marks as dirty for sync.
 */
export function updateHighlight(
  id: string,
  fields: { color?: HighlightColor; note?: string | null }
): void {
  db.update(highlights)
    .set({
      ...fields,
      updatedAt: Date.now(),
      isDirty: true,
    })
    .where(eq(highlights.id, id))
    .run()

  triggerSyncOnWrite()
}

/**
 * Soft-delete a highlight. Sets isDeleted flag and marks dirty for sync.
 */
export function deleteHighlight(id: string): void {
  db.update(highlights)
    .set({
      isDeleted: true,
      updatedAt: Date.now(),
      isDirty: true,
    })
    .where(eq(highlights.id, id))
    .run()

  triggerSyncOnWrite()
}

/**
 * Map a database row to the UI-friendly Highlight type,
 * stripping sync-only columns (userId, syncVersion, isDirty, isDeleted).
 */
function mapRowToHighlight(row: typeof highlights.$inferSelect): Highlight {
  return {
    id: row.id,
    bookId: row.bookId,
    cfiRange: row.cfiRange,
    text: row.text,
    color: row.color as HighlightColor,
    note: row.note,
    chapter: row.chapter,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  }
}
