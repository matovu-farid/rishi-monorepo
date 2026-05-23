/**
 * Incoming-file handler (Gap G27).
 *
 * Wired from `app/_layout.tsx`'s `Linking.addEventListener('url', …)`:
 *   - iOS hands us `file:///private/var/.../Inbox/book.epub` URLs when
 *     the user picks Rishi from the "Open With…" share sheet.
 *   - Android hands us `content://` URIs from the analogous intent.
 *   - The same listener also receives `rishimobile://auth/...` deep
 *     links during sign-in. `isFileUrl` filters those out so we don't
 *     accidentally double-handle them.
 *
 * The actual import drives the shared
 * `createMobileBookImportService(...)` so cover extraction, vector
 * indexing, and worker upload all run through the existing pipeline.
 */
import { Directory, Paths, File } from 'expo-file-system'
import { createMobileBookImportService } from '@/lib/book-import'
import type { BookFormat } from '@rishi/shared/book-import'

const BOOKS_DIR_NAME = 'books'

export type IncomingFileResult =
  | { ok: true; bookId: string; format: BookFormat }
  | {
      ok: false
      reason: 'unsupported' | 'import-failed' | 'duplicate-in-flight'
      error?: string
    }

// H1-02: in-flight URL deduper. iOS/Android fire BOTH `Linking.getInitialURL()`
// and an `addEventListener('url', …)` event on cold-start, so a single share-
// sheet action can call us twice in rapid succession. Without this set we'd
// generate two distinct book ids and import the same file twice. Entries are
// dropped after the import promise settles (resolved OR rejected).
const inFlight = new Set<string>()

/** Test-only: clear the in-flight set between tests. Do not call from app code. */
export function __resetInFlightForTests(): void {
  inFlight.clear()
}

/**
 * DAT-013 (#125): module-level counter folded into the fallback UUID
 * generator so two rapid incoming-file callbacks (iOS share sheet can
 * fire `getInitialURL` + `addEventListener('url')` within microseconds
 * of each other) cannot collide even if Math.random() returns the same
 * value back-to-back. The host's `crypto.randomUUID` is already
 * collision-safe and is preferred when available.
 */
let fallbackUuidCounter = 0

function generateUUID(): string {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return crypto.randomUUID()
  }
  fallbackUuidCounter = (fallbackUuidCounter + 1) & 0xffffffff
  const counter = fallbackUuidCounter
  let counterNibblesConsumed = 0
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    let r: number
    if (c === 'x' && counterNibblesConsumed < 8) {
      const shift = (7 - counterNibblesConsumed) * 4
      r = (counter >>> shift) & 0xf
      counterNibblesConsumed += 1
    } else {
      r = (Math.random() * 16) | 0
    }
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

/**
 * True for OS-delivered file URIs (file:// on iOS, content:// on
 * Android). False for our own auth deep links — those are handled by
 * `lib/auth.ts` / `WebBrowser.openAuthSessionAsync`.
 */
export function isFileUrl(url: string): boolean {
  if (!url) return false
  if (url.startsWith('rishimobile://')) return false
  return url.startsWith('file://') || url.startsWith('content://')
}

/**
 * Map a URI's extension to a `BookFormat`. Returns `null` for anything
 * the importer doesn't know how to handle — caller should surface a
 * "not supported" message rather than failing inside the importer.
 *
 * NB: `content://` URIs may not contain the extension in their path
 * (Android sometimes presents a numeric document id instead). For
 * those we still attempt to parse `?` query params, but the caller is
 * expected to enrich the URI with a hint where it can (e.g. by passing
 * `?ext=epub`).
 */
export function detectFormatFromUrl(url: string): BookFormat | null {
  const lower = url.toLowerCase()
  // Strip query string before sniffing the extension.
  const sansQuery = lower.split('?')[0]
  if (sansQuery.endsWith('.epub')) return 'epub'
  if (sansQuery.endsWith('.pdf')) return 'pdf'
  if (sansQuery.endsWith('.azw3')) return 'azw3'
  if (sansQuery.endsWith('.mobi')) return 'mobi'
  if (sansQuery.endsWith('.djvu')) return 'djvu'
  return null
}

function titleFromUrl(url: string, format: BookFormat): string {
  const sansQuery = url.split('?')[0]
  const lastSegment = sansQuery.split('/').pop() || 'Unknown Book'
  const decoded = decodeURIComponent(lastSegment)
  const extRegex = new RegExp(`\\.${format}$`, 'i')
  return decoded.replace(extRegex, '')
}

/**
 * Materialise an OS-delivered file into the per-book app-data dir and
 * hand it off to the shared book-import service. Indexing kicks off
 * fire-and-forget after the import completes.
 *
 * @returns `{ ok: true, bookId, format }` on success, otherwise
 *   `{ ok: false, reason }` — callers should surface `reason` in UI.
 */
export async function handleIncomingFile(
  url: string,
): Promise<IncomingFileResult> {
  const format = detectFormatFromUrl(url)
  if (!format) {
    return { ok: false, reason: 'unsupported' }
  }

  // H1-02: dedupe back-to-back calls for the same URL. The cold-start path
  // in `app/_layout.tsx` invokes us from `Linking.getInitialURL()` AND from
  // the `addEventListener('url')` handler that fires immediately after, so
  // without this guard a single share-sheet action imports the file twice
  // with two distinct book ids. Subsequent imports of the same URL after
  // the first one completes are still allowed (the user genuinely re-shared
  // the file from another app).
  if (inFlight.has(url)) {
    return { ok: false, reason: 'duplicate-in-flight' }
  }
  inFlight.add(url)

  try {
    return await runImport(url, format)
  } finally {
    inFlight.delete(url)
  }
}

async function runImport(
  url: string,
  format: BookFormat,
): Promise<IncomingFileResult> {
  const title = titleFromUrl(url, format)
  const bookId = generateUUID()

  // Ensure the books dir + this book's subdir exist.
  const booksDir = new Directory(Paths.document, BOOKS_DIR_NAME)
  try {
    booksDir.create({ intermediates: true, idempotent: true })
  } catch {
    /* dir may already exist — that's fine */
  }
  const bookDir = new Directory(booksDir, bookId)
  try {
    bookDir.create({ intermediates: true, idempotent: true })
  } catch {
    /* idempotent */
  }

  // For local `file://` URIs the OS hands us a real path; for
  // `content://` URIs we need the bytes copied into our sandbox before
  // the shared service can read them with `expo-file-system` APIs.
  // Both paths fall through to `service.importFromPath(uri)`; the
  // service's FsPort handles the actual copy into
  // `books/<bookId>/book.<format>`.
  const sourceUri = url

  const service = createMobileBookImportService({
    bookId,
    format,
    title,
  })

  const importResult = await service.importFromPath(sourceUri)
  if (!importResult.ok) {
    console.warn(
      `[file-handler] import failed (stage=${(importResult as { stage?: string }).stage}):`,
      (importResult as { error?: string }).error,
    )
    return {
      ok: false,
      reason: 'import-failed',
      error: (importResult as { error?: string }).error,
    }
  }

  // Indexing is fire-and-forget — same semantics as picker-driven
  // imports. We start it inside this tick so tests can observe the
  // call without waiting for a delayed microtask.
  void service
    .indexBook(
      bookId,
      undefined,
      `${bookDir.uri}/book.${format}`,
      format,
    )
    .catch((err: unknown) => {
      console.warn('[file-handler] indexBook failed:', err)
    })

  return { ok: true, bookId, format }
}

// Re-export the File factory so `app/_layout.tsx` can pass an already-
// wrapped source if it has one. Not required for the happy path.
export { File }
