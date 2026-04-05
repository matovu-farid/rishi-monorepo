import * as DocumentPicker from 'expo-document-picker'
import * as FileSystem from 'expo-file-system'
import { Book } from '@/types/book'
import { insertBook } from './book-storage'

const BOOKS_DIR = `${FileSystem.documentDirectory}books/`

export async function importEpubFile(): Promise<Book | null> {
  const result = await DocumentPicker.getDocumentAsync({
    type: 'application/epub+zip',
    copyToCacheDirectory: true,
  })

  if (result.canceled || !result.assets || result.assets.length === 0) {
    return null
  }

  const asset = result.assets[0]
  const bookId = generateUUID()
  const bookDir = `${BOOKS_DIR}${bookId}/`
  const destPath = `${bookDir}book.epub`

  // Ensure books directory exists
  await FileSystem.makeDirectoryAsync(bookDir, { intermediates: true })

  // Copy file from cache to permanent storage
  await FileSystem.copyAsync({ from: asset.uri, to: destPath })

  // Extract title from filename (strip .epub extension)
  const rawName = asset.name || 'Unknown Book'
  const title = rawName.replace(/\.epub$/i, '')

  const book: Book = {
    id: bookId,
    title,
    author: 'Unknown',
    coverPath: null,
    filePath: destPath,
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
