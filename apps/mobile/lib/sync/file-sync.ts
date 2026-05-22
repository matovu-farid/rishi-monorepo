import * as Crypto from 'expo-crypto'
import { File, Directory, Paths } from 'expo-file-system'
import { apiClient } from '@/lib/api'
import { db } from '@/lib/db'
import { books } from '@rishi/shared/schema'
import { eq } from 'drizzle-orm'
import { useDownloadErrorStore } from '@/lib/sync/download-error-store'
import type {
  UploadUrlRequest,
  UploadUrlResponse,
  UploadUrlError,
  DownloadUrlRequest,
  DownloadUrlResponse,
} from '@rishi/shared/sync-types'

/**
 * Typed error thrown when the worker rejects an /upload-url request because
 * the user would exceed a storage cap. Consumers should pattern-match on
 * `.code` to surface a localized message. The worker returns:
 *   - 413 FILE_TOO_LARGE        — single file > 800 MB
 *   - 507 BOOK_LIMIT_REACHED    — per-user book count cap hit
 *   - 507 STORAGE_LIMIT_REACHED — per-user total bytes cap hit
 */
export class UploadLimitError extends Error {
  readonly code: UploadUrlError['code']
  readonly limit: number
  readonly current?: number
  readonly status: number

  constructor(payload: UploadUrlError, status: number) {
    super(payload.error)
    this.name = 'UploadLimitError'
    this.code = payload.code
    this.limit = payload.limit
    this.current = payload.current
    this.status = status
  }
}

/**
 * Compute SHA-256 hash of a book file.
 * Reads file as base64, then hashes the base64 string.
 * For MVP: books are typically 1-20MB, acceptable performance.
 */
export async function hashBookFile(filePath: string): Promise<string> {
  try {
    const file = new File(filePath)
    const base64 = await file.base64()
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
 *
 * `fileSize` is required by the worker (post storage-cap update) so it can
 * enforce per-file (800 MB) and per-user (10 GB / 500-book) limits BEFORE
 * handing back a presigned URL. When the worker rejects with 413 or 507,
 * this throws `UploadLimitError` so callers can switch on `.code`.
 *
 * Returns the R2 key for storing in the book record.
 */
export async function uploadBookFile(
  filePath: string,
  fileHash: string,
  format: 'epub' | 'pdf' | 'mobi' | 'djvu',
  fileSize: number,
): Promise<{ r2Key: string }> {
  const contentTypes: Record<string, string> = {
    epub: 'application/epub+zip',
    pdf: 'application/pdf',
    mobi: 'application/x-mobipocket-ebook',
    djvu: 'image/vnd.djvu',
  }
  const contentType = contentTypes[format] ?? 'application/octet-stream'

  // Request presigned upload URL from Worker
  const res = await apiClient('/api/sync/upload-url', {
    method: 'POST',
    body: JSON.stringify({ fileHash, contentType, fileSize } satisfies UploadUrlRequest),
  })

  if (!res.ok) {
    // Storage-cap rejection: try to decode the typed UploadUrlError payload.
    // The worker uses 413 for per-file overage and 507 for both per-user
    // count + per-user bytes caps. Anything else is an unexpected failure
    // and is rethrown as a plain Error.
    if (res.status === 413 || res.status === 507) {
      let payload: UploadUrlError | null = null
      try {
        payload = (await res.json()) as UploadUrlError
      } catch {
        payload = null
      }
      if (payload && typeof payload.code === 'string') {
        throw new UploadLimitError(payload, res.status)
      }
    }
    throw new Error(`Upload URL request failed: ${res.status} ${res.statusText}`)
  }

  const data: UploadUrlResponse = await res.json()

  // Dedup: file already exists in R2
  if (data.exists) {
    return { r2Key: data.r2Key }
  }

  // Upload file to R2 via presigned URL (direct to R2, NOT via apiClient)
  const file = new File(filePath)
  const bytes = await file.bytes()

  const uploadRes = await fetch(data.uploadUrl!, {
    method: 'PUT',
    body: bytes,
    headers: { 'Content-Type': contentType },
  })

  if (!uploadRes.ok) {
    throw new Error(`R2 upload failed: ${uploadRes.status} ${uploadRes.statusText}`)
  }

  return { r2Key: data.r2Key }
}

/**
 * Download a book file from R2 on-demand.
 * Used when opening a book synced from another device that has no local file.
 * Downloads via presigned URL, saves to local books directory, updates DB filePath.
 */
export async function downloadBookFile(
  bookId: string,
  r2Key: string,
  format: 'epub' | 'pdf' | 'mobi' | 'djvu'
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

    const arrayBuffer = await downloadRes.arrayBuffer()
    const bytes = new Uint8Array(arrayBuffer)

    // Step 1: Write to a temporary file
    const tmpFile = new File(bookDir, `book.${format}.tmp`)
    tmpFile.write(bytes)

    // Step 2: Atomically move temp file to final path.
    // File.move() uses OS-level rename which is atomic on most filesystems,
    // so the destination either has the complete file or doesn't exist.
    const destFile = new File(bookDir, `book.${format}`)
    try {
      tmpFile.move(destFile)
    } catch (moveErr) {
      // DAT-003 recovery:
      //   - KEEP the tmp file on disk. The bytes are correct (R2 fetch
      //     succeeded); only the rename failed. A retry should re-attempt
      //     the move first, not re-pay the R2 download cost.
      //   - Mark the book row with `fileNeedsRedownload=true` so the UI
      //     and sync engine can identify it. We deliberately do NOT set
      //     `filePath` — that would point at a non-existent destination.
      //   - Push a failure entry into the download-error store so any
      //     subscribed UI (sync status indicator, library screen) can
      //     render a retry affordance with the most recent error context.
      const reason = moveErr instanceof Error ? moveErr.message : String(moveErr)
      try {
        db.update(books)
          .set({ fileNeedsRedownload: true })
          .where(eq(books.id, bookId))
          .run()
      } catch {
        // If the DB write fails (e.g. column missing on a downgraded build),
        // we still want the in-memory store to carry the failure so the UI
        // can offer a retry path. Swallow and continue.
      }
      useDownloadErrorStore.getState().recordFailure({
        bookId,
        r2Key,
        format,
        reason,
      })
      throw new Error(`Failed to move temp file to final path: ${reason}`)
    }

    // Step 3: Update DB only after the file is safely in place. Also clear
    // the recovery flag in case this download was a successful retry of a
    // previously-failed move.
    db.update(books)
      .set({ filePath: destFile.uri, fileNeedsRedownload: false })
      .where(eq(books.id, bookId))
      .run()
    // Clear any prior failure entry for this book so the UI removes the
    // retry chip once we succeed.
    useDownloadErrorStore.getState().clearFailure(bookId)

    return destFile.uri
  } catch (error) {
    throw new Error(`Failed to download book file: ${error}`)
  }
}
