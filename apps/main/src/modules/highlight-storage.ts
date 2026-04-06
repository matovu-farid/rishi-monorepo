import { db } from './kysley';

/**
 * Save or update a highlight in the SQLite highlights table.
 * Called when the user creates/modifies a highlight in the epub.js reader.
 *
 * @param bookSyncId - The book's sync_id (UUID), NOT the integer id.
 *   Highlights.book_id must reference the sync_id for sync to work.
 * @param cfiRange - The epub CFI range of the highlight
 * @param text - The highlighted text content
 * @param color - Highlight color (default: 'yellow')
 * @param note - Optional note attached to the highlight
 * @param chapter - Optional chapter name
 */
export async function saveHighlight(params: {
  bookSyncId: string;
  cfiRange: string;
  text: string;
  color?: string;
  note?: string;
  chapter?: string;
}): Promise<string> {
  const id = crypto.randomUUID();
  const now = Date.now();

  // Check if a highlight already exists for this cfiRange + book
  const existing = await db
    .selectFrom('highlights')
    .select('id')
    .where('book_id', '=', params.bookSyncId)
    .where('cfi_range', '=', params.cfiRange)
    .where('is_deleted', '=', 0)
    .executeTakeFirst();

  if (existing) {
    // Update existing highlight
    await db.updateTable('highlights')
      .set({
        text: params.text,
        color: params.color ?? 'yellow',
        note: params.note ?? null,
        chapter: params.chapter ?? null,
        updated_at: now,
        is_dirty: 1,
      })
      .where('id', '=', existing.id)
      .execute();
    return existing.id;
  }

  // Insert new highlight
  await db.insertInto('highlights')
    .values({
      id,
      book_id: params.bookSyncId,
      cfi_range: params.cfiRange,
      text: params.text,
      color: params.color ?? 'yellow',
      note: params.note ?? null,
      chapter: params.chapter ?? null,
      created_at: now,
      updated_at: now,
      sync_version: 0,
      is_dirty: 1,
      is_deleted: 0,
    })
    .execute();

  return id;
}

/**
 * Soft-delete a highlight (marks is_deleted=1, is_dirty=1 for sync).
 */
export async function deleteHighlight(bookSyncId: string, cfiRange: string): Promise<void> {
  await db.updateTable('highlights')
    .set({
      is_deleted: 1,
      is_dirty: 1,
      updated_at: Date.now(),
    })
    .where('book_id', '=', bookSyncId)
    .where('cfi_range', '=', cfiRange)
    .execute();
}

/**
 * Get all active (non-deleted) highlights for a book.
 * Used to restore highlights when opening an epub.
 */
export async function getHighlightsForBook(bookSyncId: string) {
  return db
    .selectFrom('highlights')
    .selectAll()
    .where('book_id', '=', bookSyncId)
    .where('is_deleted', '=', 0)
    .execute();
}
