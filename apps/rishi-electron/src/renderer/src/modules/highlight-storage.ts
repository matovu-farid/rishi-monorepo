/**
 * Highlight storage module using typed Electron IPC handlers.
 * Mirrors the Tauri Kysely-based highlight-storage.ts.
 */

export interface HighlightRow {
  id: string
  bookId: string
  cfiRange: string
  text: string
  color: string
  note: string
  chapter: string | null
  createdAt: string
  updatedAt: number | null
  syncId: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
}

/**
 * Save or update a highlight in the SQLite highlights table.
 */
export async function saveHighlight(params: {
  bookSyncId: string
  cfiRange: string
  text: string
  color?: string
  note?: string
  chapter?: string
}): Promise<string> {
  return window.electron.highlightsSave(params)
}

/**
 * Soft-delete a highlight by bookId + cfiRange (marks is_deleted=1, is_dirty=1 for sync).
 */
export async function deleteHighlight(bookSyncId: string, cfiRange: string): Promise<void> {
  await window.electron.highlightsDelete(bookSyncId, cfiRange)
}

/**
 * Get all active (non-deleted) highlights for a book.
 */
export async function getHighlightsForBook(bookId: string): Promise<HighlightRow[]> {
  return window.electron.highlightsList(bookId)
}

/**
 * Soft-delete a highlight by its ID.
 */
export async function deleteHighlightById(highlightId: string): Promise<void> {
  await window.electron.highlightsDeleteById(highlightId)
}

/**
 * Update the note on an existing highlight.
 */
export async function updateHighlightNote(highlightId: string, note: string): Promise<void> {
  await window.electron.highlightsUpdateNote(highlightId, note)
}

/**
 * Update the color of an existing highlight.
 */
export async function updateHighlightColor(highlightId: string, color: string): Promise<void> {
  await window.electron.highlightsUpdateColor(highlightId, color)
}
