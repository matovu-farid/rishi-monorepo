import { readFile, mkdir, writeFile, rename, remove } from '@tauri-apps/plugin-fs';
import { getAuthToken } from './auth';
import type { UploadUrlRequest, UploadUrlResponse, DownloadUrlRequest, DownloadUrlResponse } from '@rishi/shared/sync-types';
import { db } from './kysley';
import { appDataDir } from '@tauri-apps/api/path';

const WORKER_URL = 'https://rishi-worker.faridmato90.workers.dev';

async function getAuthHeaders(): Promise<Record<string, string>> {
  const token = await getAuthToken();
  return {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
}

/**
 * Compute SHA-256 hash of a book file using Web Crypto API.
 * Reads file via Tauri FS plugin, hashes with crypto.subtle.
 */
export async function hashBookFile(filePath: string): Promise<string> {
  const fileBytes = await readFile(filePath);
  const hashBuffer = await crypto.subtle.digest('SHA-256', fileBytes);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
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
    djvu: 'image/vnd.djvu',
  };
  const contentType = contentTypes[format] ?? 'application/octet-stream';
  const headers = await getAuthHeaders();

  // Request presigned upload URL
  const uploadUrlController = new AbortController();
  const uploadUrlTimeout = setTimeout(() => uploadUrlController.abort(), 30_000);
  let res: Response;
  try {
    res = await fetch(`${WORKER_URL}/api/sync/upload-url`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ fileHash, contentType } satisfies UploadUrlRequest),
      signal: uploadUrlController.signal,
    });
  } catch (err) {
    if (uploadUrlController.signal.aborted) {
      throw new Error('Upload URL request timed out after 30 seconds');
    }
    throw err;
  } finally {
    clearTimeout(uploadUrlTimeout);
  }

  if (!res.ok) {
    throw new Error(`Upload URL request failed: ${res.status} ${res.statusText}`);
  }

  const data: UploadUrlResponse = await res.json();

  // Dedup: file already exists in R2
  if (data.exists) {
    return { r2Key: data.r2Key };
  }

  // Read file and upload to R2 via presigned URL
  const fileBytes = await readFile(filePath);
  const uploadController = new AbortController();
  const uploadTimeout = setTimeout(() => uploadController.abort(), 60_000);
  let uploadRes: Response;
  try {
    if (!data.uploadUrl) {
      throw new Error('Server response missing uploadUrl');
    }
    uploadRes = await fetch(data.uploadUrl, {
      method: 'PUT',
      body: fileBytes,
      headers: { 'Content-Type': contentType },
      signal: uploadController.signal,
    });
  } catch (err) {
    if (uploadController.signal.aborted) {
      throw new Error('R2 upload timed out after 60 seconds');
    }
    throw err;
  } finally {
    clearTimeout(uploadTimeout);
  }

  if (!uploadRes.ok) {
    throw new Error(`R2 upload failed: ${uploadRes.status} ${uploadRes.statusText}`);
  }

  return { r2Key: data.r2Key };
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
  const headers = await getAuthHeaders();

  // Request presigned download URL
  const dlUrlController = new AbortController();
  const dlUrlTimeout = setTimeout(() => dlUrlController.abort(), 30_000);
  let res: Response;
  try {
    res = await fetch(`${WORKER_URL}/api/sync/download-url`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ r2Key } satisfies DownloadUrlRequest),
      signal: dlUrlController.signal,
    });
  } catch (err) {
    if (dlUrlController.signal.aborted) {
      throw new Error('Download URL request timed out after 30 seconds');
    }
    throw err;
  } finally {
    clearTimeout(dlUrlTimeout);
  }

  if (!res.ok) {
    throw new Error(`Download URL request failed: ${res.status} ${res.statusText}`);
  }

  const data: DownloadUrlResponse = await res.json();

  // Download file
  const dlController = new AbortController();
  const dlTimeout = setTimeout(() => dlController.abort(), 60_000);
  let downloadRes: Response;
  try {
    downloadRes = await fetch(data.downloadUrl, { signal: dlController.signal });
  } catch (err) {
    if (dlController.signal.aborted) {
      throw new Error('R2 download timed out after 60 seconds');
    }
    throw err;
  } finally {
    clearTimeout(dlTimeout);
  }
  if (!downloadRes.ok) {
    throw new Error(`R2 download failed: ${downloadRes.status} ${downloadRes.statusText}`);
  }

  // Save to app data dir using Tauri FS (atomic write-then-rename)
  const dataDir = await appDataDir();
  const destPath = `${dataDir}/books/${bookIntegerId}/book.${format}`;
  const tmpPath = `${destPath}.tmp`;

  // Ensure directory exists
  await mkdir(`${dataDir}/books/${bookIntegerId}`, { recursive: true }).catch((err) => console.warn('[file-sync] mkdir failed:', err));

  // Step 1: Write to a temporary file
  const bytes = new Uint8Array(await downloadRes.arrayBuffer());
  await writeFile(tmpPath, bytes);

  // Step 2: Atomically rename temp file to final path.
  // rename() is atomic on most filesystems, so the destination either
  // has the complete file or the old content -- never a partial write.
  try {
    await rename(tmpPath, destPath);
  } catch (renameErr) {
    // Clean up the temp file on failure
    await remove(tmpPath).catch((err) => console.warn('[file-sync] temp file cleanup failed:', err));
    throw new Error(`Failed to rename temp file to final path: ${renameErr}`);
  }

  // Step 3: Update DB filepath only after the file is safely in place.
  // If the DB update fails, revert the rename to avoid orphaning the file.
  try {
    await db.updateTable('books')
      .set({ filepath: destPath })
      .where('id', '=', bookIntegerId)
      .execute();
  } catch (dbError) {
    console.error('[file-sync] DB update failed, reverting rename:', dbError);
    try { await rename(destPath, tmpPath); } catch { /* best effort */ }
    throw dbError;
  }

  return destPath;
}
