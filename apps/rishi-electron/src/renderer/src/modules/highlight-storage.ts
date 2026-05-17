/**
 * Highlight storage module using typed Electron IPC handlers.
 * Mirrors the Tauri Kysely-based highlight-storage.ts.
 */

// HighlightRow is the IPC boundary type — single source of truth lives in the
// preload contract so main and renderer always agree on the wire shape.
import type { HighlightRow } from '../../../preload/types'
export type { HighlightRow }

export interface PdfLocator {
  page: number
  rects: Array<{ x: number; y: number; w: number; h: number }>
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
  return window.electron.highlightsSave({
    format: 'epub',
    bookSyncId: params.bookSyncId,
    cfiRange: params.cfiRange,
    locator: null,
    text: params.text,
    color: params.color,
    note: params.note,
    chapter: params.chapter
  })
}

/**
 * Save a new PDF highlight in the SQLite highlights table.
 */
export async function saveHighlightPdf(params: {
  bookSyncId: string
  locator: PdfLocator
  text: string
  color?: string
  note?: string
  chapter?: string | null
}): Promise<string> {
  return await window.electron.highlightsSave({
    format: 'pdf',
    bookSyncId: params.bookSyncId,
    cfiRange: null,
    locator: JSON.stringify(params.locator),
    text: params.text,
    color: params.color ?? 'yellow',
    note: params.note ?? '',
    chapter: params.chapter ?? null
  })
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
