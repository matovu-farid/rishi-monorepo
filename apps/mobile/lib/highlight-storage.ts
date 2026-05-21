import * as Crypto from 'expo-crypto'
import { db } from '@/lib/db'
import { highlights } from '@rishi/shared/schema'
import { eq, and, desc } from 'drizzle-orm'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'
import type { Highlight, HighlightColor } from '@/types/highlight'
import {
  encodePdfCfiRange,
  decodePdfCfiRange,
  isPdfCfiRange,
  type PdfLocator,
} from '@rishi/shared/types/pdf-locator'

/**
 * PDF-specific highlight projection used by the PDF reader UI. The
 * locator is materialized from the `cfiRange` column on read so the UI
 * code never deals with the storage encoding directly.
 *
 * Storage encoding: the row's `cfiRange` column carries
 * `pdf:<json-encoded PdfLocator>`. The format prefix is required to
 * disambiguate EPUB and PDF rows in the shared `highlights` table —
 * see `packages/shared/src/types/pdf-locator.ts` for the spec.
 */
export interface PdfHighlight {
  id: string
  bookId: string
  cfiRange: string
  locator: PdfLocator
  text: string
  color: HighlightColor
  note: string | null
  chapter: string | null
  createdAt: number
  updatedAt: number
}

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
 * Undo a soft-delete by flipping `isDeleted` back to false and bumping
 * `updatedAt`. Used by the EPUB / PDF reader popover's "Undo" toast.
 *
 * Mirrors electron's `restoreHighlight` (apps/rishi-electron/.../modules/
 * highlight-storage.ts). The row's id is the only identity — color, text,
 * note, chapter are preserved across the soft-delete cycle because we
 * never null them out on delete.
 */
export function restoreHighlight(id: string): void {
  db.update(highlights)
    .set({
      isDeleted: false,
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

// ─── PDF highlights ───────────────────────────────────────────────────────
//
// PDF rows live in the same `highlights` table as EPUB rows but encode
// their `PdfLocator` in the `cfiRange` column with a `pdf:` prefix. This
// is a mobile-side convention that avoids a schema migration; electron
// achieves the same with a separate `format` + `locator` column pair.
// Sync to D1 carries the prefixed cfiRange verbatim, so a row written by
// either client deserializes on the other.

/**
 * Insert a new PDF highlight. Generates a UUID, encodes the locator as
 * a pdf:-prefixed cfiRange, and triggers a sync push.
 */
export function insertPdfHighlight(params: {
  bookId: string
  locator: PdfLocator
  text: string
  color: HighlightColor
  note?: string | null
  chapter?: string | null
}): PdfHighlight {
  const now = Date.now()
  const id = Crypto.randomUUID()
  const cfiRange = encodePdfCfiRange(params.locator)

  db.insert(highlights)
    .values({
      id,
      bookId: params.bookId,
      cfiRange,
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
    cfiRange,
    locator: params.locator,
    text: params.text,
    color: params.color,
    note: params.note ?? null,
    chapter: params.chapter ?? null,
    createdAt: now,
    updatedAt: now,
  }
}

/**
 * Get all non-deleted PDF highlights for a book. Rows whose cfiRange
 * doesn't carry the pdf: prefix (i.e. EPUB rows) are filtered out.
 * Decoded locators that fail validation are skipped (treated as
 * corrupt) — the alternative of throwing would break the whole reader
 * for one bad row.
 */
export function getPdfHighlightsByBookId(bookId: string): PdfHighlight[] {
  const rows = db
    .select()
    .from(highlights)
    .where(and(eq(highlights.bookId, bookId), eq(highlights.isDeleted, false)))
    .orderBy(desc(highlights.createdAt))
    .all()

  const out: PdfHighlight[] = []
  for (const row of rows) {
    if (!isPdfCfiRange(row.cfiRange)) continue
    const locator = decodePdfCfiRange(row.cfiRange)
    if (!locator) continue
    out.push({
      id: row.id,
      bookId: row.bookId,
      cfiRange: row.cfiRange,
      locator,
      text: row.text,
      color: row.color as HighlightColor,
      note: row.note,
      chapter: row.chapter,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    })
  }
  return out
}
