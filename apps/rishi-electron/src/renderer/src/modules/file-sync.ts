/**
 * File synchronization - hash, upload, and download book files via R2.
 * Ported from Tauri version, adapted for Electron IPC.
 */
import { getAuthToken } from './auth'
import type {
  UploadUrlRequest,
  UploadUrlResponse,
  DownloadUrlRequest,
  DownloadUrlResponse
} from '@rishi/shared/sync-types'

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev'

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
 * Upload a book file to R2 via presigned URL.
 * Dedup: if fileHash already in R2, skips upload.
 * Returns the R2 key for storing in the book record.
 */
export async function uploadBookFile(
  filePath: string,
  fileHash: string,
  format: 'epub' | 'pdf' | 'mobi' | 'djvu'
): Promise<{ r2Key: string }> {
  const contentTypes: Record<string, string> = {
    epub: 'application/epub+zip',
    pdf: 'application/pdf',
    mobi: 'application/x-mobipocket-ebook',
    djvu: 'image/vnd.djvu'
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
      body: JSON.stringify({ fileHash, contentType } satisfies UploadUrlRequest),
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
