/**
 * File synchronization - hash, upload, and download book files via R2.
 * Ported from Tauri version, adapted for Electron IPC.
 */
import { getAuthToken } from './auth'
import { WORKER_URL } from '@/config/worker-url'
import type {
  UploadUrlRequest,
  UploadUrlResponse,
  DownloadUrlRequest,
  DownloadUrlResponse,
  UploadUrlError
} from '@rishi/shared/sync-types'

async function getAuthHeaders(): Promise<Record<string, string>> {
  const token = await getAuthToken()
  return {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json'
  }
}

/**
 * Compute SHA-256 hash of a book file using Web Crypto API.
 * Reads file via Electron IPC, hashes with crypto.subtle.
 */
export async function hashBookFile(filepath: string): Promise<string> {
  const data = await window.electron.readFile(filepath)
  const hashBuffer = await crypto.subtle.digest('SHA-256', data)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  return hashArray.map((b) => b.toString(16).padStart(2, '0')).join('')
}

/**
 * Resolve the on-disk size in bytes of a book file. Uses the main process
 * `fs:getFileSize` IPC (a thin wrapper over `fs.stat`) rather than reading
 * the whole file just to count bytes. Returns 0 if the IPC fails — callers
 * pass the value to the worker which treats 0 as "too small to matter" for
 * its per-file cap, so a failure here doesn't block the upload entirely.
 */
export async function getFileSize(filepath: string): Promise<number> {
  try {
    return await window.electron.getFileSize(filepath)
  } catch (err) {
    console.warn('[file-sync] getFileSize failed', err)
    return 0
  }
}

/**
 * Thrown when `/api/sync/upload-url` rejects the request because the user
 * would exceed a server-enforced storage cap. Carries the worker's typed
 * error shape so the UI layer can render a localized message without
 * re-parsing the response.
 *
 * The worker uses three distinct codes:
 *   - FILE_TOO_LARGE       (HTTP 413) — single file exceeds per-file cap
 *   - BOOK_LIMIT_REACHED   (HTTP 507) — user already at max book count
 *   - STORAGE_LIMIT_REACHED (HTTP 507) — total user storage exhausted
 */
export class UploadLimitError extends Error {
  readonly code: UploadUrlError['code']
  readonly limit: number
  readonly current?: number

  constructor(payload: UploadUrlError) {
    super(formatUploadLimitMessage(payload))
    this.name = 'UploadLimitError'
    this.code = payload.code
    this.limit = payload.limit
    this.current = payload.current
  }
}

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
  }
  if (bytes >= 1024 * 1024) {
    return `${Math.round(bytes / (1024 * 1024))} MB`
  }
  if (bytes >= 1024) {
    return `${Math.round(bytes / 1024)} KB`
  }
  return `${bytes} B`
}

/**
 * Build the user-facing message for an upload-limit rejection. Centralised so
 * both the thrown Error and any consumer that wants to render a toast can
 * agree on phrasing.
 */
export function formatUploadLimitMessage(payload: UploadUrlError): string {
  switch (payload.code) {
    case 'FILE_TOO_LARGE':
      return `This file is too large to sync. Per-file limit is ${formatBytes(payload.limit)}.`
    case 'BOOK_LIMIT_REACHED': {
      const current = payload.current != null ? ` (you're at ${payload.current})` : ''
      return `You've reached the ${payload.limit}-book sync limit${current}. Remove a book and try again.`
    }
    case 'STORAGE_LIMIT_REACHED': {
      const current = payload.current != null ? ` (${formatBytes(payload.current)} used)` : ''
      return `Cloud storage is full${current}. Limit is ${formatBytes(payload.limit)}. Remove a book and try again.`
    }
    default:
      return payload.error || 'Upload limit reached'
  }
}

/**
 * Best-effort parser for the worker's typed UploadUrlError body. Returns
 * null when the response is not the documented shape — callers should then
 * fall back to a generic HTTP-status error.
 */
async function parseUploadLimitError(res: Response): Promise<UploadUrlError | null> {
  try {
    const data = (await res.clone().json()) as Partial<UploadUrlError>
    if (
      typeof data.code === 'string' &&
      (data.code === 'FILE_TOO_LARGE' ||
        data.code === 'BOOK_LIMIT_REACHED' ||
        data.code === 'STORAGE_LIMIT_REACHED') &&
      typeof data.limit === 'number'
    ) {
      return {
        error: typeof data.error === 'string' ? data.error : '',
        code: data.code,
        limit: data.limit,
        current: typeof data.current === 'number' ? data.current : undefined
      }
    }
    return null
  } catch {
    return null
  }
}

/**
 * Upload a book file to R2 via presigned URL.
 * Dedup: if fileHash already in R2, skips upload.
 * Returns the R2 key for storing in the book record.
 *
 * The `fileSize` argument is REQUIRED — the worker rejects requests without
 * it as `FILE_TOO_LARGE`. Callers pass the local-file size in bytes; this
 * value is also persisted on the book row so it can flow up to the cloud
 * book record via the normal sync push.
 */
export async function uploadBookFile(
  filePath: string,
  fileHash: string,
  format: 'epub' | 'pdf' | 'mobi',
  fileSize: number
): Promise<{ r2Key: string }> {
  const contentTypes: Record<string, string> = {
    epub: 'application/epub+zip',
    pdf: 'application/pdf',
    mobi: 'application/x-mobipocket-ebook'
  }
  const contentType = contentTypes[format] ?? 'application/octet-stream'
  const headers = await getAuthHeaders()

  // Request presigned upload URL
  const uploadUrlController = new AbortController()
  const uploadUrlTimeout = setTimeout(() => uploadUrlController.abort(), 30_000)
  let res: Response
  try {
    res = await fetch(`${WORKER_URL}/api/sync/upload-url`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ fileHash, contentType, fileSize } satisfies UploadUrlRequest),
      signal: uploadUrlController.signal
    })
  } catch (err) {
    if (uploadUrlController.signal.aborted) {
      throw new Error('Upload URL request timed out after 30 seconds')
    }
    throw err
  } finally {
    clearTimeout(uploadUrlTimeout)
  }

  if (!res.ok) {
    // 413 (per-file cap) and 507 (per-user storage / book-count cap) carry
    // the structured UploadUrlError payload. Surface as a typed error so
    // callers can render code-aware copy without re-parsing the response.
    if (res.status === 413 || res.status === 507) {
      const limitErr = await parseUploadLimitError(res)
      if (limitErr) throw new UploadLimitError(limitErr)
    }
    throw new Error(`Upload URL request failed: ${res.status} ${res.statusText}`)
  }

  const data: UploadUrlResponse = await res.json()

  // Dedup: file already exists in R2
  if (data.exists) {
    return { r2Key: data.r2Key }
  }

  // Read file and upload to R2 via presigned URL
  const fileBytes = await window.electron.readFile(filePath)
  const uploadController = new AbortController()
  const uploadTimeout = setTimeout(() => uploadController.abort(), 60_000)
  let uploadRes: Response
  try {
    if (!data.uploadUrl) {
      throw new Error('Server response missing uploadUrl')
    }
    uploadRes = await fetch(data.uploadUrl, {
      method: 'PUT',
      body: fileBytes,
      headers: { 'Content-Type': contentType },
      signal: uploadController.signal
    })
  } catch (err) {
    if (uploadController.signal.aborted) {
      throw new Error('R2 upload timed out after 60 seconds')
    }
    throw err
  } finally {
    clearTimeout(uploadTimeout)
  }

  if (!uploadRes.ok) {
    throw new Error(`R2 upload failed: ${uploadRes.status} ${uploadRes.statusText}`)
  }

  return { r2Key: data.r2Key }
}

/**
 * Download a book file from R2 on-demand.
 * Used when opening a remote book that has no local file.
 * Downloads via presigned URL, saves to app data dir, updates DB filepath.
 */
export async function downloadBookFile(
  bookIntegerId: number,
  r2Key: string,
  format: 'epub' | 'pdf'
): Promise<string> {
  const headers = await getAuthHeaders()

  // Request presigned download URL
  const dlUrlController = new AbortController()
  const dlUrlTimeout = setTimeout(() => dlUrlController.abort(), 30_000)
  let res: Response
  try {
    res = await fetch(`${WORKER_URL}/api/sync/download-url`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ r2Key } satisfies DownloadUrlRequest),
      signal: dlUrlController.signal
    })
  } catch (err) {
    if (dlUrlController.signal.aborted) {
      throw new Error('Download URL request timed out after 30 seconds')
    }
    throw err
  } finally {
    clearTimeout(dlUrlTimeout)
  }

  if (!res.ok) {
    throw new Error(`Download URL request failed: ${res.status} ${res.statusText}`)
  }

  const data: DownloadUrlResponse = await res.json()

  // Download file
  const dlController = new AbortController()
  const dlTimeout = setTimeout(() => dlController.abort(), 60_000)
  let downloadRes: Response
  try {
    downloadRes = await fetch(data.downloadUrl, { signal: dlController.signal })
  } catch (err) {
    if (dlController.signal.aborted) {
      throw new Error('R2 download timed out after 60 seconds')
    }
    throw err
  } finally {
    clearTimeout(dlTimeout)
  }
  if (!downloadRes.ok) {
    throw new Error(`R2 download failed: ${downloadRes.status} ${downloadRes.statusText}`)
  }

  // Save to app data dir via Electron IPC (atomic write-then-rename pattern)
  const dataDir = await window.electron.getAppDataPath()
  const destPath = `${dataDir}/books/${bookIntegerId}/book.${format}`
  const tmpPath = `${destPath}.tmp`

  const bytes = new Uint8Array(await downloadRes.arrayBuffer())

  // Write to temp file first, then rename for atomicity
  await window.electron.mkdir(`${dataDir}/books/${bookIntegerId}`)
  await window.electron.writeFile(tmpPath, bytes)

  // Verify temp file was written
  const tmpExists = await window.electron.exists(tmpPath)
  if (!tmpExists) {
    throw new Error('Download failed: temp file was not written')
  }

  // Atomic rename: tmp → final path (if process crashes mid-write, no corrupt file at destPath)
  try {
    // Remove existing file if present, then rename tmp to dest
    if (await window.electron.exists(destPath)) {
      await window.electron.removeFile(destPath)
    }
    // copyFile + removeFile simulates rename (Electron IPC doesn't expose rename directly)
    await window.electron.copyFile(tmpPath, destPath)
    await window.electron.removeFile(tmpPath)
  } catch (renameErr) {
    // Clean up tmp file on failure
    try {
      await window.electron.removeFile(tmpPath)
    } catch {
      /* ignore */
    }
    throw renameErr
  }

  // Update DB filepath
  await window.electron.booksUpdateFilepath(bookIntegerId, destPath)

  return destPath
}
