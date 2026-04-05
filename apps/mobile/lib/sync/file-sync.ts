import * as Crypto from 'expo-crypto'
import { File, Directory, Paths } from 'expo-file-system'
import { apiClient } from '@/lib/api'
import { db } from '@/lib/db'
import { books } from '@rishi/shared/schema'
import { eq } from 'drizzle-orm'
import type {
  UploadUrlRequest,
  UploadUrlResponse,
  DownloadUrlRequest,
  DownloadUrlResponse,
} from '@rishi/shared/sync-types'

/**
 * Compute SHA-256 hash of a book file.
 * Reads file as base64, then hashes the base64 string.
 * For MVP: books are typically 1-20MB, acceptable performance.
 */
export async function hashBookFile(filePath: string): Promise<string> {
  try {
    const file = new File(filePath)
    const base64 = file.base64()
    const hash = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      base64
    )
    return hash
  } catch (error) {
    throw new Error(`Failed to hash book file: ${error}`)
  }
}

/**
 * Upload a book file to R2 via presigned URL.
 * Performs dedup check: if the same fileHash already exists in R2, skips upload.
 * Returns the R2 key for storing in the book record.
 */
export async function uploadBookFile(
  filePath: string,
  fileHash: string,
  format: 'epub' | 'pdf'
): Promise<{ r2Key: string }> {
  const contentType = format === 'epub' ? 'application/epub+zip' : 'application/pdf'

  try {
    // Request presigned upload URL from Worker
    const res = await apiClient('/api/sync/upload-url', {
      method: 'POST',
      body: JSON.stringify({ fileHash, contentType } satisfies UploadUrlRequest),
    })

    if (!res.ok) {
      throw new Error(`Upload URL request failed: ${res.status} ${res.statusText}`)
    }

    const data: UploadUrlResponse = await res.json()

    // Dedup: file already exists in R2
    if (data.exists) {
      return { r2Key: data.r2Key }
    }

    // Upload file to R2 via presigned URL (direct to R2, NOT via apiClient)
    const file = new File(filePath)
    const blob = await file.blob()

    const uploadRes = await fetch(data.uploadUrl!, {
      method: 'PUT',
      body: blob,
      headers: { 'Content-Type': contentType },
    })

    if (!uploadRes.ok) {
      throw new Error(`R2 upload failed: ${uploadRes.status} ${uploadRes.statusText}`)
    }

    return { r2Key: data.r2Key }
  } catch (error) {
    throw new Error(`Failed to upload book file: ${error}`)
  }
}

/**
 * Download a book file from R2 on-demand.
 * Used when opening a book synced from another device that has no local file.
 * Downloads via presigned URL, saves to local books directory, updates DB filePath.
 */
export async function downloadBookFile(
  bookId: string,
  r2Key: string,
  format: 'epub' | 'pdf'
): Promise<string> {
  try {
    // Request presigned download URL from Worker
    const res = await apiClient('/api/sync/download-url', {
      method: 'POST',
      body: JSON.stringify({ r2Key } satisfies DownloadUrlRequest),
    })

    if (!res.ok) {
      throw new Error(`Download URL request failed: ${res.status} ${res.statusText}`)
    }

    const data: DownloadUrlResponse = await res.json()

    // Ensure local directory exists
    const bookDir = new Directory(Paths.document, 'books', bookId)
    bookDir.create({ intermediates: true, idempotent: true })

    // Download file from R2 (direct to R2, NOT via apiClient)
    const downloadRes = await fetch(data.downloadUrl)

    if (!downloadRes.ok) {
      throw new Error(`R2 download failed: ${downloadRes.status} ${downloadRes.statusText}`)
    }

    const blob = await downloadRes.blob()

    // Write to local file
    const destFile = new File(bookDir, `book.${format}`)
    destFile.write(blob)

    // Update the book record with the local filePath
    db.update(books)
      .set({ filePath: destFile.uri })
      .where(eq(books.id, bookId))
      .run()

    return destFile.uri
  } catch (error) {
    throw new Error(`Failed to download book file: ${error}`)
  }
}
