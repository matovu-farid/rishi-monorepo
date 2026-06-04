/**
 * API bridge - replaces Tauri invoke() commands with Electron IPC.
 * All functions mirror the original Tauri command signatures.
 */

import { getAuthToken } from '@/modules/auth'
import { WORKER_URL } from '@/config/worker-url'

// Re-export types that match the original generated types

/**
 * Build auth headers for outbound calls to our worker.
 *
 * Must use `Authorization: Bearer …` — the `Cookie` header is a forbidden
 * request header in Chromium's fetch implementation and is silently stripped
 * from renderer-side requests, leaving the call unauthenticated.
 */
async function getAuthHeaders(): Promise<Record<string, string>> {
  const token = await getAuthToken()
  return token ? { Authorization: `Bearer ${token}` } : {}
}

/**
 * Legacy User shape — kept around for renderer code that still consumes
 * the old Clerk-style fields. Prefer `AuthUser` from `@preload/types` for
 * new code.
 */
export interface User {
  id: string
  firstName?: string | null
  lastName?: string | null
  fullName?: string | null
  username?: string | null
  imageUrl?: string | null
  hasImage: boolean
  lastSignInAt?: number | null
  externalId?: string | null
}

export interface Book {
  id: number
  kind: string
  cover: number[]
  title: string
  author: string
  publisher: string
  filepath: string
  location: string
  coverKind: string
  version: number
  syncId?: string | null
  fileHash?: string | null
  fileR2Key?: string | null
  coverR2Key?: string | null
  fileSize?: number | null
  format: string
  currentCfi?: string | null
  currentPage?: number | null
  userId?: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
  lastParagraph?: string | null
  // Sharing provenance (Plan 2 Task 22 / Task 34): set when the book was
  // delivered through a P2P sharing session. Local-only books leave these
  // fields NULL. Surfacing them on the Book type lets the renderer flag
  // shared books in the library UI without a separate query.
  source?: string | null
  receivedFromUserId?: string | null
  receivedAt?: number | null
}

export interface BookInsertable {
  id?: number | null
  kind: string
  cover: number[]
  title: string
  author: string
  publisher: string
  filepath: string
  location: string
  coverKind: string
  version: number
  syncId?: string | null
  fileHash?: string | null
  fileR2Key?: string | null
  coverR2Key?: string | null
  fileSize?: number | null
  format?: string | null
  currentCfi?: string | null
  currentPage?: number | null
  userId?: string | null
  syncVersion?: number | null
  isDirty?: number | null
  isDeleted?: number | null
}

export interface BookData {
  id: string
  kind: string
  cover: number[]
  title?: string | null
  author?: string | null
  publisher?: string | null
  filepath: string
  location: string
  coverKind?: string | null
  version: number
}

export interface PageData {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

export interface ChunkDataInsertable {
  id?: number | null
  pageNumber: number
  bookId: number
  data: string
}

export interface TextSearchResult {
  id: number
  pageNumber: number
  bookId: number
  data: string
  snippet: string
}

export interface SearchResult {
  id: number
  distance: number
}

export interface EmbedParam {
  text: string
  metadata: { id: number; pageNumber: number; bookId: number }
}

export interface EmbedResult {
  dim: number
  embedding: number[]
  text?: string | null
  metadata: { id: number; pageNumber: number; bookId: number }
}

export interface Vector {
  id: number
  vector: number[]
}

export type FileSizeCheck = 'ok' | 'warn' | 'blocked'

export interface OAuthStateResponse {
  state: string
  codeChallenge: string
}

export interface AuthStatusResponse {
  status?: string | null
  retryCount?: number | null
  createdAt?: number | null
  error?: string | null
}

// Helper to get the electron API
function api() {
  return window.electron
}

// ---- Books ----
export async function getBooks(): Promise<Book[]> {
  return api().getBooks()
}
export async function findBookByHash(hash: string): Promise<Book | null> {
  return api().findBookByHash(hash)
}

export async function getBookFilepaths(): Promise<string[]> {
  return api().getBookFilepaths()
}

/**
 * Lazy-load a single book's cover BLOB. `getBooks()` no longer ships cover
 * bytes inline (see #190) — components that render a cover should call this
 * on mount and decode the result into a blob URL. Returns null when the
 * book id doesn't exist.
 */
export async function getCover(bookId: number): Promise<number[] | null> {
  return api().getCover(bookId)
}
export async function getBook(params: { bookId: number }): Promise<Book | null> {
  return api().getBook(params.bookId)
}
export async function saveBook(params: { book: BookInsertable }): Promise<Book> {
  return api().saveBook(params.book)
}
export async function deleteBook(params: { bookId: number }): Promise<void> {
  return api().deleteBook(params.bookId)
}
export async function updateBookCover(params: {
  bookId: number
  newCover: number[]
}): Promise<void> {
  return api().updateBookCover(params.bookId, params.newCover)
}
export async function updateBookLocation(params: {
  bookId: number
  newLocation: string
}): Promise<void> {
  return api().updateBookLocation(params.bookId, params.newLocation)
}
export async function updateBookLastParagraph(params: {
  bookId: number
  lastParagraph: string | null
}): Promise<void> {
  return api().updateBookLastParagraph(params.bookId, params.lastParagraph)
}
export async function hasSavedEpubData(params: { bookId: number }): Promise<boolean> {
  return api().hasSavedEpubData(params.bookId)
}

/** Renderer-side alias for {@link hasSavedEpubData}. The IPC channel name
 *  `hasSavedEpubData` is preserved on the preload/main side, but consumers
 *  outside the EPUB path should prefer this name — the function checks
 *  whether *any* indexed chunk data exists for a book, regardless of format. */
export async function hasIndexedBookData(params: { bookId: number }): Promise<boolean> {
  return api().hasSavedEpubData(params.bookId)
}

export interface BookOutline {
  title: string
  author: string | null
  chapters: string[]
}

export async function getBookOutline(bookId: number): Promise<BookOutline> {
  return api().getBookOutline(bookId)
}

// ---- Chunks/Page Data ----
export async function savePageDataMany(params: { pageData: ChunkDataInsertable[] }): Promise<void> {
  return api().savePageDataMany(params.pageData)
}
export async function getAllPageDataByBookId(params: { bookId: number }): Promise<PageData[]> {
  return api().getAllPageDataByBookId(params.bookId)
}

// ---- Search ----
export async function searchBookText(params: {
  query: string
  bookId: number
}): Promise<TextSearchResult[]> {
  return api().searchBookText(params.query, params.bookId)
}

// ---- Vectors ----
export async function embed(params: { embedparams: EmbedParam[] }): Promise<EmbedResult[]> {
  return api().embed(params.embedparams)
}
export async function saveVectors(params: {
  name: string
  dim: number
  vectors: Vector[]
}): Promise<void> {
  return api().saveVectors(params.name, params.dim, params.vectors)
}
export async function searchVectors(params: {
  name: string
  query: number[]
  dim: number
  k: number
}): Promise<SearchResult[]> {
  return api().searchVectors(params.name, params.query, params.dim, params.k)
}
export async function hasVectorsForBook(bookId: number): Promise<boolean> {
  return api().hasVectorsForBook(bookId)
}

// ---- File Formats ----
export async function getBookData(params: { path: string }): Promise<BookData> {
  return api().getBookData(params.path)
}
export async function getPdfData(params: { path: string }): Promise<BookData> {
  return api().getPdfData(params.path)
}
export async function getMobiData(params: { path: string }): Promise<BookData> {
  return api().getMobiData(params.path)
}
export async function getAzw3Data(params: { path: string }): Promise<BookData> {
  return api().getAzw3Data(params.path)
}
export async function getMobiChapter(params: {
  path: string
  chapterIndex: number
}): Promise<string> {
  return api().getMobiChapter(params.path, params.chapterIndex)
}
export async function getMobiChapterCount(params: { path: string }): Promise<number> {
  return api().getMobiChapterCount(params.path)
}
export async function getMobiText(params: {
  path: string
  chapterIndex: number
}): Promise<string[]> {
  return api().getMobiText(params.path, params.chapterIndex)
}

// ---- File System ----
export async function checkFileSize(params: {
  path: string
  format: string
}): Promise<FileSizeCheck> {
  return api().checkFileSize(params.path, params.format)
}
export async function unzip(params: { filePath: string; outDir: string }): Promise<string> {
  return api().unzip(params.filePath, params.outDir)
}

// ---- Scanner ----
export async function getDefaultBookFolders(): Promise<string[]> {
  return api().getDefaultBookFolders()
}
export async function scanForBooks(params: { mode: string }): Promise<number> {
  return api().scanForBooks(params.mode)
}
export async function cancelScan(): Promise<void> {
  return api().cancelScan()
}

// ---- Auth ----
export async function getUserFromStore(): Promise<User | null> {
  return api().getUserFromStore()
}

// ---- Debug ----
export async function dumpErrorCmd(params: {
  source: string
  location: string
  error: string
  context?: string | null
  stack?: string | null
}): Promise<void> {
  return api().dumpError(params)
}
export async function readErrorDump(): Promise<string> {
  return api().readErrorDump()
}
export async function clearErrorDump(): Promise<void> {
  return api().clearErrorDump()
}

// ---- Utilities ----
export async function isDev(): Promise<boolean> {
  return api().isDev()
}
export async function getDevBypassSecret(): Promise<string | null> {
  return api().getDevBypassSecret()
}

export async function getRealtimeClientSecret(language: string): Promise<string> {
  const authHeaders = await getAuthHeaders()
  const headers: Record<string, string> = { ...authHeaders }

  if (Object.keys(authHeaders).length === 0) {
    const devBypass = await api().getDevBypassSecret()
    if (devBypass) {
      headers['X-Dev-Bypass'] = devBypass
    } else {
      throw new Error('Not authenticated')
    }
  }

  const url = new URL(`${WORKER_URL}/api/realtime/client_secrets`)
  url.searchParams.set('language', language)

  const response = await fetch(url.toString(), {
    method: 'GET',
    headers
  })

  if (!response.ok) {
    const bodyText = await response.text().catch(() => '')
    console.error('[realtime] worker returned non-OK', response.status, bodyText)
    throw new Error(`Worker API responded with status ${response.status}: ${bodyText}`)
  }

  const data = (await response.json()) as { client_secret?: { value?: string } }
  const secret = data.client_secret?.value
  if (!secret) {
    throw new Error('No client_secret in worker response')
  }
  return secret
}

/**
 * Send a recorded audio blob to the worker's Deepgram-backed STT endpoint and
 * return the transcript. Used to replay speech captured during the voice-chat
 * connect window as a text message. Throws on transport/auth failure; callers
 * decide whether to swallow it (best-effort feature).
 */
export async function transcribeAudio(blob: Blob): Promise<string> {
  const authHeaders = await getAuthHeaders()
  const headers: Record<string, string> = {
    ...authHeaders,
    'Content-Type': blob.type || 'audio/webm'
  }

  if (Object.keys(authHeaders).length === 0) {
    const devBypass = await api().getDevBypassSecret()
    if (devBypass) {
      headers['X-Dev-Bypass'] = devBypass
    } else {
      throw new Error('Not authenticated')
    }
  }

  const response = await fetch(`${WORKER_URL}/api/audio/transcribe`, {
    method: 'POST',
    headers,
    body: blob
  })

  if (!response.ok) {
    const bodyText = await response.text().catch(() => '')
    throw new Error(`Worker API responded with status ${response.status}: ${bodyText}`)
  }

  const data = (await response.json()) as { transcript?: string }
  return data.transcript ?? ''
}

/**
 * Generic worker fetch helper for `@rishi/shared` clients that take an
 * `ApiFetch` (path, init?) => Promise<Response>. Prepends WORKER_URL,
 * injects Authorization (or dev-bypass) headers, and passes through caller
 * headers/body untouched. Throws on missing auth — callers using
 * `reportRealtimeUsage` already catch and never bubble billing failures
 * into voice-chat teardown.
 */
export async function workerFetch(path: string, init?: RequestInit): Promise<Response> {
  const authHeaders = await getAuthHeaders()
  const headers = new Headers(init?.headers)
  for (const [k, v] of Object.entries(authHeaders)) headers.set(k, v)
  if (Object.keys(authHeaders).length === 0) {
    const devBypass = await api().getDevBypassSecret()
    if (devBypass) {
      headers.set('X-Dev-Bypass', devBypass)
    } else {
      throw new Error('Not authenticated')
    }
  }
  return fetch(`${WORKER_URL}${path}`, { ...init, headers })
}

// ---- Helpers ----
/**
 * Convert a local file path to a URL that the renderer can load.
 * Uses the custom `local-file://` protocol registered in the main process,
 * which serves files from the filesystem securely (like Tauri's asset://).
 */
export function convertFileSrc(filepath: string): string {
  if (filepath.startsWith('local-file://')) return filepath
  if (filepath.startsWith('file://')) return filepath.replace('file://', 'local-file://')
  if (filepath.startsWith('/')) return `local-file://${filepath}`
  return filepath
}
