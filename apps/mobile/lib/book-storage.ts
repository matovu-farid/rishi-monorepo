import { Book } from '@/types/book'
import { db } from '@/lib/db'
import { books } from '@rishi/shared/schema'
import { eq, and, desc } from 'drizzle-orm'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'

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
    format: row.format as 'epub' | 'pdf',
    currentCfi: row.currentCfi,
    currentPage: row.currentPage,
    createdAt: row.createdAt,
  }
}
