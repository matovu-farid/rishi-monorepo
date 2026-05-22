import { File } from 'expo-file-system'
import { Book } from '@/types/book'
import { db } from '@/lib/db'
import { books } from '@rishi/shared/schema'
import { eq, and, or, desc, isNotNull } from 'drizzle-orm'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'
import { downloadBookFile } from '@/lib/sync/file-sync'

export function insertBook(book: Book): void {
  db.insert(books)
    .values({
      id: book.id,
      title: book.title,
      author: book.author,
      coverPath: book.coverPath,
      filePath: book.filePath,
      format: book.format,
      currentCfi: book.currentCfi,
      currentPage: book.currentPage,
      createdAt: book.createdAt,
      updatedAt: Date.now(),
      isDirty: true,
      isDeleted: false,
    })
    .run()
  triggerSyncOnWrite()
}

export function getBooks(): Book[] {
  const rows = db
    .select()
    .from(books)
    .where(eq(books.isDeleted, false))
    .orderBy(desc(books.createdAt))
    .all()
  return rows.map(mapRowToBook)
}

export function getBookById(id: string): Book | null {
  const row = db
    .select()
    .from(books)
    .where(and(eq(books.id, id), eq(books.isDeleted, false)))
    .get()
  return row ? mapRowToBook(row) : null
}

/**
 * Optional hooks for `getBookForReading`. Callers can pass `onDownloadStart`
 * to flip a "Downloading..." UI state the moment the lazy R2 fetch begins —
 * this fires BEFORE the network call so the reader screen can paint the
 * download copy before the await resolves.
 */
export interface GetBookForReadingOptions {
  onDownloadStart?: () => void
}

/**
 * Get a book ready for reading. If the book was synced from another device
 * and has no local file, download it from R2 on-demand.
 */
export async function getBookForReading(
  id: string,
  opts: GetBookForReadingOptions = {},
): Promise<Book | null> {
  const row = db
    .select()
    .from(books)
    .where(and(eq(books.id, id), eq(books.isDeleted, false)))
    .get()

  if (!row) return null

  // Check if local file exists
  const hasLocalFile = row.filePath && new File(row.filePath).exists

  if (!hasLocalFile && row.fileR2Key) {
    // Download from R2 -- this updates filePath in DB. R2 stores azw3
    // files under the 'mobi' format key (same parser), so collapse the
    // union here before handing off to the download port.
    const downloadFormat: 'epub' | 'pdf' | 'mobi' | 'djvu' =
      row.format === 'azw3' ? 'mobi' : (row.format as 'epub' | 'pdf' | 'mobi' | 'djvu')
    // Signal "we're about to download" BEFORE the await so the consumer
    // can flip its "Downloading..." UI state synchronously.
    opts.onDownloadStart?.()
    await downloadBookFile(id, row.fileR2Key, downloadFormat)
    // Re-fetch the updated row
    const updated = db
      .select()
      .from(books)
      .where(eq(books.id, id))
      .get()
    return updated ? mapRowToBook(updated) : null
  }

  return mapRowToBook(row)
}

export function updateBookCfi(id: string, cfi: string): void {
  db.update(books)
    .set({ currentCfi: cfi, updatedAt: Date.now(), isDirty: true })
    .where(eq(books.id, id))
    .run()
  triggerSyncOnWrite()
}

export function updateBookPage(id: string, page: number): void {
  db.update(books)
    .set({ currentPage: page, updatedAt: Date.now(), isDirty: true })
    .where(eq(books.id, id))
    .run()
  triggerSyncOnWrite()
}

export function deleteBook(id: string): void {
  db.update(books)
    .set({ isDeleted: true, updatedAt: Date.now(), isDirty: true })
    .where(eq(books.id, id))
    .run()
  triggerSyncOnWrite()
}

export function getLastReadBook(): Book | null {
  const row = db
    .select()
    .from(books)
    .where(
      and(
        eq(books.isDeleted, false),
        or(isNotNull(books.currentCfi), isNotNull(books.currentPage))
      )
    )
    .orderBy(desc(books.updatedAt))
    .limit(1)
    .get()
  return row ? mapRowToBook(row) : null
}

/**
 * Sentinel persisted to `coverPath` when cover extraction failed during
 * import (P1-AC). Mirrors `COVER_EXTRACTION_FAILED_SENTINEL` in
 * `lib/book-import/adapters.ts` — duplicated here to avoid the
 * book-storage module pulling in the heavier book-import deps.
 *
 * Kept as a string sentinel rather than a dedicated schema column to
 * dodge a migration round-trip; a future migration can promote it.
 */
const COVER_FAILED_SENTINEL = '__failed'

function mapRowToBook(row: typeof books.$inferSelect): Book {
  // P1-AC: surface the sentinel as a derived boolean and normalize
  // `coverPath` to null so existing call sites (image rendering,
  // letter-tile fallback) keep working unchanged.
  const failed = row.coverPath === COVER_FAILED_SENTINEL
  return {
    id: row.id,
    title: row.title,
    author: row.author,
    coverPath: failed ? null : row.coverPath,
    filePath: row.filePath,
    format: row.format as Book['format'],
    currentCfi: row.currentCfi,
    currentPage: row.currentPage,
    createdAt: row.createdAt,
    // Extra field — typed as optional on the Book interface.
    coverExtractionFailed: failed,
  }
}
