import { File } from 'expo-file-system'
import { Book } from '@/types/book'
import { db } from '@/lib/db'
import { books } from '@rishi/shared/schema'
import { eq, and, desc } from 'drizzle-orm'
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
 * Get a book ready for reading. If the book was synced from another device
 * and has no local file, download it from R2 on-demand.
 */
export async function getBookForReading(id: string): Promise<Book | null> {
  const row = db
    .select()
    .from(books)
    .where(and(eq(books.id, id), eq(books.isDeleted, false)))
    .get()

  if (!row) return null

  // Check if local file exists
  const hasLocalFile = row.filePath && new File(row.filePath).exists

  if (!hasLocalFile && row.fileR2Key) {
    // Download from R2 -- this updates filePath in DB
    await downloadBookFile(
      id,
      row.fileR2Key,
      row.format as Book['format']
    )
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

function mapRowToBook(row: typeof books.$inferSelect): Book {
  return {
    id: row.id,
    title: row.title,
    author: row.author,
    coverPath: row.coverPath,
    filePath: row.filePath,
    format: row.format as Book['format'],
    currentCfi: row.currentCfi,
    currentPage: row.currentPage,
    createdAt: row.createdAt,
  }
}
