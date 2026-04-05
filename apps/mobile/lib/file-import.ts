import { File, Directory, Paths } from 'expo-file-system'
import { Book } from '@/types/book'
import { insertBook } from '@/lib/book-storage'

const BOOKS_DIR = new Directory(Paths.document, 'books')

export async function importEpubFile(): Promise<Book | null> {
  const pickedFile = await File.pickFileAsync(undefined, 'application/epub+zip')

  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return null
  }

  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile

  const bookId = generateUUID()
  const bookDir = new Directory(BOOKS_DIR, bookId)

  // Ensure books/bookId directory exists
  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true })
  }
  bookDir.create({ intermediates: true, idempotent: true })

  // Copy file from picked location to permanent storage
  const destFile = new File(bookDir, 'book.epub')
  sourceFile.copy(destFile)

  // Extract title from URI (strip .epub extension)
  const uriParts = sourceFile.uri.split('/')
  const rawName = decodeURIComponent(uriParts[uriParts.length - 1] || 'Unknown Book')
  const title = rawName.replace(/\.epub$/i, '')

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destFile.uri,
    format: 'epub',
    currentCfi: null,
    createdAt: Date.now(),
  }

  insertBook(book)
  return book
}

function generateUUID(): string {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return crypto.randomUUID()
  }
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}
