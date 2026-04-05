import { Book } from '@/types/book'
import { getDb } from '@/lib/db'

export function insertBook(book: Book): void {
  const db = getDb()
  db.runSync(
    'INSERT INTO books (id, title, author, cover_path, file_path, format, current_cfi, current_page, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    [book.id, book.title, book.author, book.coverPath, book.filePath, book.format, book.currentCfi, book.currentPage, book.createdAt]
  )
}

export function getBooks(): Book[] {
  const db = getDb()
  const rows = db.getAllSync('SELECT * FROM books ORDER BY created_at DESC')
  return rows.map(mapRowToBook)
}

export function getBookById(id: string): Book | null {
  const db = getDb()
  const row = db.getFirstSync('SELECT * FROM books WHERE id = ?', [id])
  return row ? mapRowToBook(row) : null
}

export function updateBookCfi(id: string, cfi: string): void {
  const db = getDb()
  db.runSync('UPDATE books SET current_cfi = ? WHERE id = ?', [cfi, id])
}

export function updateBookPage(id: string, page: number): void {
  const db = getDb()
  db.runSync('UPDATE books SET current_page = ? WHERE id = ?', [page, id])
}

export function deleteBook(id: string): void {
  const db = getDb()
  db.runSync('DELETE FROM books WHERE id = ?', [id])
}

function mapRowToBook(row: any): Book {
  return {
    id: row.id,
    title: row.title,
    author: row.author,
    coverPath: row.cover_path,
    filePath: row.file_path,
    format: row.format as 'epub' | 'pdf',
    currentCfi: row.current_cfi,
    currentPage: row.current_page ?? null,
    createdAt: row.created_at,
  }
}
