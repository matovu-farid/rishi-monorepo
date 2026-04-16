import { File, Directory, Paths } from 'expo-file-system'
import { Book } from '@/types/book'
import { insertBook } from '@/lib/book-storage'
import { hashBookFile, uploadBookFile } from '@/lib/sync/file-sync'
import { db } from '@/lib/db'
import { books } from '@rishi/shared/schema'
import { eq } from 'drizzle-orm'

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
    currentPage: null,
    createdAt: Date.now(),
  }

  insertBook(book)

  // Hash and upload file to R2 in background (non-blocking)
  hashBookFile(destFile.uri)
    .then((fileHash) => {
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run()

      uploadBookFile(destFile.uri, fileHash, 'epub')
        .then(({ r2Key }) => {
          db.update(books)
            .set({ fileR2Key: r2Key, isDirty: true })
            .where(eq(books.id, bookId))
            .run()
        })
        .catch((err) => {
          console.warn('Book upload failed (will retry on next sync):', err)
        })
    })
    .catch((err) => {
      console.warn('Book hashing failed:', err)
    })

  return book
}

export async function importPdfFile(): Promise<Book | null> {
  const pickedFile = await File.pickFileAsync(undefined, 'application/pdf')

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
  const destFile = new File(bookDir, 'book.pdf')
  sourceFile.copy(destFile)

  // Extract title from URI (strip .pdf extension)
  const uriParts = sourceFile.uri.split('/')
  const rawName = decodeURIComponent(uriParts[uriParts.length - 1] || 'Unknown Book')
  const title = rawName.replace(/\.pdf$/i, '')

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destFile.uri,
    format: 'pdf',
    currentCfi: null,
    currentPage: null,
    createdAt: Date.now(),
  }

  insertBook(book)

  // Hash and upload file to R2 in background (non-blocking)
  hashBookFile(destFile.uri)
    .then((fileHash) => {
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run()

      uploadBookFile(destFile.uri, fileHash, 'pdf')
        .then(({ r2Key }) => {
          db.update(books)
            .set({ fileR2Key: r2Key, isDirty: true })
            .where(eq(books.id, bookId))
            .run()
        })
        .catch((err) => {
          console.warn('Book upload failed (will retry on next sync):', err)
        })
    })
    .catch((err) => {
      console.warn('Book hashing failed:', err)
    })

  return book
}

export async function importMobiFile(): Promise<Book | null> {
  const pickedFile = await File.pickFileAsync(undefined, 'application/x-mobipocket-ebook')

  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return null
  }

  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile

  const bookId = generateUUID()
  const bookDir = new Directory(BOOKS_DIR, bookId)

  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true })
  }
  bookDir.create({ intermediates: true, idempotent: true })

  // Detect exact extension from picked file
  const ext = sourceFile.uri.toLowerCase().endsWith('.azw3') ? 'azw3' : 'mobi'
  const destFile = new File(bookDir, `book.${ext}`)
  sourceFile.copy(destFile)

  const uriParts = sourceFile.uri.split('/')
  const rawName = decodeURIComponent(uriParts[uriParts.length - 1] || 'Unknown Book')
  const title = rawName.replace(/\.(mobi|azw3)$/i, '')

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destFile.uri,
    format: 'mobi',
    currentCfi: null,
    currentPage: null,
    createdAt: Date.now(),
  }

  insertBook(book)

  hashBookFile(destFile.uri)
    .then((fileHash) => {
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run()

      uploadBookFile(destFile.uri, fileHash, 'mobi')
        .then(({ r2Key }) => {
          db.update(books)
            .set({ fileR2Key: r2Key, isDirty: true })
            .where(eq(books.id, bookId))
            .run()
        })
        .catch((err) => {
          console.warn('Book upload failed (will retry on next sync):', err)
        })
    })
    .catch((err) => {
      console.warn('Book hashing failed:', err)
    })

  return book
}

export async function importDjvuFile(): Promise<Book | null> {
  const pickedFile = await File.pickFileAsync(undefined, 'image/vnd.djvu')

  if (!pickedFile || (Array.isArray(pickedFile) && pickedFile.length === 0)) {
    return null
  }

  const sourceFile = Array.isArray(pickedFile) ? pickedFile[0] : pickedFile

  const bookId = generateUUID()
  const bookDir = new Directory(BOOKS_DIR, bookId)

  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true })
  }
  bookDir.create({ intermediates: true, idempotent: true })

  const destFile = new File(bookDir, 'book.djvu')
  sourceFile.copy(destFile)

  const uriParts = sourceFile.uri.split('/')
  const rawName = decodeURIComponent(uriParts[uriParts.length - 1] || 'Unknown Book')
  const title = rawName.replace(/\.djvu$/i, '')

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destFile.uri,
    format: 'djvu',
    currentCfi: null,
    currentPage: null,
    createdAt: Date.now(),
  }

  insertBook(book)

  hashBookFile(destFile.uri)
    .then((fileHash) => {
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run()

      uploadBookFile(destFile.uri, fileHash, 'djvu')
        .then(({ r2Key }) => {
          db.update(books)
            .set({ fileR2Key: r2Key, isDirty: true })
            .where(eq(books.id, bookId))
            .run()
        })
        .catch((err) => {
          console.warn('Book upload failed (will retry on next sync):', err)
        })
    })
    .catch((err) => {
      console.warn('Book hashing failed:', err)
    })

  return book
}

type BookFormat = 'epub' | 'pdf' | 'mobi' | 'djvu'

function detectFormatFromUrl(url: string): BookFormat | null {
  const pathname = new URL(url).pathname.toLowerCase()
  if (pathname.endsWith('.epub')) return 'epub'
  if (pathname.endsWith('.pdf')) return 'pdf'
  if (pathname.endsWith('.mobi') || pathname.endsWith('.azw3')) return 'mobi'
  if (pathname.endsWith('.djvu')) return 'djvu'
  return null
}

function detectFormatFromContentType(contentType: string | null): BookFormat | null {
  if (!contentType) return null
  if (contentType.includes('application/epub+zip')) return 'epub'
  if (contentType.includes('application/pdf')) return 'pdf'
  if (contentType.includes('application/x-mobipocket-ebook')) return 'mobi'
  if (contentType.includes('image/vnd.djvu')) return 'djvu'
  return null
}

function extractTitleFromUrl(url: string): string {
  const pathname = new URL(url).pathname
  const filename = decodeURIComponent(pathname.split('/').pop() || 'Unknown Book')
  return filename.replace(/\.(epub|pdf|mobi|azw3|djvu)$/i, '')
}

export async function importBookFromUrl(url: string): Promise<Book> {
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    throw new Error('Invalid URL — must start with http:// or https://')
  }

  let format = detectFormatFromUrl(url)

  if (!format) {
    try {
      const headRes = await fetch(url, { method: 'HEAD' })
      format = detectFormatFromContentType(headRes.headers.get('content-type'))
    } catch {
      // HEAD failed, will try download anyway and check content-type there
    }
  }

  const downloadRes = await fetch(url)

  if (!downloadRes.ok) {
    throw new Error(`Download failed: ${downloadRes.status} ${downloadRes.statusText}`)
  }

  if (!format) {
    format = detectFormatFromContentType(downloadRes.headers.get('content-type'))
  }

  if (!format) {
    throw new Error('Unsupported format — only EPUB, PDF, MOBI, and DJVU are supported')
  }

  const arrayBuffer = await downloadRes.arrayBuffer()
  const bytes = new Uint8Array(arrayBuffer)

  const bookId = generateUUID()
  const bookDir = new Directory(BOOKS_DIR, bookId)

  if (!BOOKS_DIR.exists) {
    BOOKS_DIR.create({ intermediates: true })
  }
  bookDir.create({ intermediates: true, idempotent: true })

  const destFile = new File(bookDir, `book.${format}`)
  destFile.write(bytes)

  const title = extractTitleFromUrl(url)

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destFile.uri,
    format,
    currentCfi: null,
    currentPage: null,
    createdAt: Date.now(),
  }

  insertBook(book)

  hashBookFile(destFile.uri)
    .then((fileHash) => {
      db.update(books)
        .set({ fileHash, isDirty: true })
        .where(eq(books.id, bookId))
        .run()

      uploadBookFile(destFile.uri, fileHash, format!)
        .then(({ r2Key }) => {
          db.update(books)
            .set({ fileR2Key: r2Key, isDirty: true })
            .where(eq(books.id, bookId))
            .run()
        })
        .catch((err) => {
          console.warn('Book upload failed (will retry on next sync):', err)
        })
    })
    .catch((err) => {
      console.warn('Book hashing failed:', err)
    })

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
