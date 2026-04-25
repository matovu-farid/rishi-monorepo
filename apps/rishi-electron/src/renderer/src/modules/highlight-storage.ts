/**
 * Highlight storage module using Electron IPC (window.electron.dbQuery/dbRun).
 * Mirrors the Tauri Kysely-based highlight-storage.ts.
 */

export interface HighlightRow {
  id: string;
  book_id: string;
  cfi_range: string;
  text: string;
  color: string;
  note: string | null;
  chapter: string | null;
  created_at: number;
  updated_at: number;
  sync_version: number;
  is_dirty: number;
  is_deleted: number;
}

/**
 * Save or update a highlight in the SQLite highlights table.
 */
export async function saveHighlight(params: {
  bookId: string;
  cfiRange: string;
  text: string;
  color?: string;
  note?: string;
  chapter?: string;
}): Promise<string> {
  const now = Date.now();

  // Check if a highlight already exists for this cfiRange + book
  const existing = (await window.electron.dbQuery(
    `SELECT id FROM highlights WHERE book_id = ? AND cfi_range = ? AND is_deleted = 0 LIMIT 1`,
    [params.bookId, params.cfiRange]
  )) as HighlightRow[];

  if (existing.length > 0) {
    // Update existing highlight
    await window.electron.dbRun(
      `UPDATE highlights SET text = ?, color = ?, note = ?, chapter = ?, updated_at = ?, is_dirty = 1 WHERE id = ?`,
      [
        params.text,
        params.color ?? 'yellow',
        params.note ?? null,
        params.chapter ?? null,
        now,
        existing[0].id,
      ]
    );
    return existing[0].id;
  }

  // Insert new highlight
  const id = crypto.randomUUID();
  await window.electron.dbRun(
    `INSERT INTO highlights (id, book_id, cfi_range, text, color, note, chapter, created_at, updated_at, sync_version, is_dirty, is_deleted)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 0)`,
    [
      id,
      params.bookId,
      params.cfiRange,
      params.text,
      params.color ?? 'yellow',
      params.note ?? null,
      params.chapter ?? null,
      now,
      now,
    ]
  );

  return id;
}

/**
 * Soft-delete a highlight by bookId + cfiRange (marks is_deleted=1, is_dirty=1 for sync).
 */
export async function deleteHighlight(bookSyncId: string, cfiRange: string): Promise<void> {
  await window.electron.dbRun(
    `UPDATE highlights SET is_deleted = 1, is_dirty = 1, updated_at = ? WHERE book_id = ? AND cfi_range = ?`,
    [Date.now(), bookSyncId, cfiRange]
  );
}

/**
 * Get all active (non-deleted) highlights for a book.
 */
export async function getHighlightsForBook(bookId: string): Promise<HighlightRow[]> {
  return (await window.electron.dbQuery(
    `SELECT * FROM highlights WHERE book_id = ? AND is_deleted = 0`,
    [bookId]
  )) as HighlightRow[];
}

/**
 * Soft-delete a highlight by its ID.
 */
export async function deleteHighlightById(highlightId: string): Promise<void> {
  await window.electron.dbRun(
    `UPDATE highlights SET is_deleted = 1, is_dirty = 1, updated_at = ? WHERE id = ?`,
    [Date.now(), highlightId]
  );
}

/**
 * Update the note on an existing highlight.
 */
export async function updateHighlightNote(highlightId: string, note: string): Promise<void> {
  await window.electron.dbRun(
    `UPDATE highlights SET note = ?, updated_at = ?, is_dirty = 1 WHERE id = ?`,
    [note, Date.now(), highlightId]
  );
}

/**
 * Update the color of an existing highlight.
 */
export async function updateHighlightColor(highlightId: string, color: string): Promise<void> {
  await window.electron.dbRun(
    `UPDATE highlights SET color = ?, updated_at = ?, is_dirty = 1 WHERE id = ?`,
    [color, Date.now(), highlightId]
  );
}
