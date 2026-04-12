import { readFile, mkdir, writeFile } from '@tauri-apps/plugin-fs';
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
  const res = await fetch(`${WORKER_URL}/api/sync/upload-url`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ fileHash, contentType } satisfies UploadUrlRequest),
  });

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
  const uploadRes = await fetch(data.uploadUrl!, {
    method: 'PUT',
    body: fileBytes,
    headers: { 'Content-Type': contentType },
  });

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
  const res = await fetch(`${WORKER_URL}/api/sync/download-url`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ r2Key } satisfies DownloadUrlRequest),
  });

  if (!res.ok) {
    throw new Error(`Download URL request failed: ${res.status} ${res.statusText}`);
  }

  const data: DownloadUrlResponse = await res.json();

  // Download file
  const downloadRes = await fetch(data.downloadUrl);
  if (!downloadRes.ok) {
    throw new Error(`R2 download failed: ${downloadRes.status} ${downloadRes.statusText}`);
  }

  // Save to app data dir using Tauri FS
  const dataDir = await appDataDir();
  const destPath = `${dataDir}/books/${bookIntegerId}/book.${format}`;

  // Ensure directory exists
  await mkdir(`${dataDir}/books/${bookIntegerId}`, { recursive: true }).catch(() => {});

  // Write file
  const bytes = new Uint8Array(await downloadRes.arrayBuffer());
  await writeFile(destPath, bytes);

  // Update DB filepath
  await db.updateTable('books')
    .set({ filepath: destPath })
    .where('id', '=', bookIntegerId)
    .execute();

  return destPath;
}
