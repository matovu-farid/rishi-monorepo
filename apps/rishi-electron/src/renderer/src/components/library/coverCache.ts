import type { Book } from '@/lib/api'
import { getCover } from '@/lib/api'

// Module-level caches survive library remounts (e.g., navigating back from a
// reader). Two pieces are needed to avoid the white flash on re-entry:
//   1. URL cache: skips re-running URL.createObjectURL on every mount.
//   2. Image cache: holds a detached HTMLImageElement per cover. Keeping a
//      live Image reference prevents the browser from evicting the decoded
//      pixels when the visible <img> unmounts. On remount the new <img> hits
//      the same blob URL and the browser reuses the warm decode → paints on
//      first frame instead of flashing white.
// Both entries are released in revokeCachedCoverUrl when a book is deleted or
// when the underlying cover bytes change (e.g. PDF first-page capture in
// updateStoredCoverImage). Cover bytes are lazy-loaded from main via
// `getCover(bookId)` — see #190.
const coverUrlCache = new Map<number, string>()
const coverImageCache = new Map<number, HTMLImageElement>()
const coverFetchInFlight = new Map<number, Promise<string | null>>()

function bytesToBlobUrl(bytes: number[]): string | null {
  if (bytes.length === 0) return null
  const uint8Array = new Uint8Array(bytes)
  let mimeType = 'image/jpeg'
  if (uint8Array.length >= 8) {
    if (uint8Array[0] === 0x89 && uint8Array[1] === 0x50) mimeType = 'image/png'
    else if (uint8Array[0] === 0xff && uint8Array[1] === 0xd8) mimeType = 'image/jpeg'
    else if (uint8Array[0] === 0x47 && uint8Array[1] === 0x49) mimeType = 'image/gif'
    else if (uint8Array[0] === 0x52 && uint8Array[1] === 0x49 && uint8Array[8] === 0x57)
      mimeType = 'image/webp'
  }
  return URL.createObjectURL(new Blob([uint8Array], { type: mimeType }))
}

/**
 * Synchronous read for first-paint hydration; mirrors loadCoverUrl's
 * Map without forcing the caller to know about the cache shape.
 */
export function getCachedCoverUrl(bookId: number): string | null {
  return coverUrlCache.get(bookId) ?? null
}

export function hasCachedCoverUrl(bookId: number): boolean {
  return coverUrlCache.has(bookId)
}

/**
 * Populate the module-level cover cache for a given book. Coalesces
 * concurrent calls per book id so two card mounts don't issue two IPC
 * round-trips. If `book.cover` already has bytes (e.g., a freshly imported
 * book whose row still has them inlined), skip the IPC and decode locally.
 */
export function loadCoverUrl(book: Book): Promise<string | null> {
  const cached = coverUrlCache.get(book.id)
  if (cached !== undefined) return Promise.resolve(cached)

  const pending = coverFetchInFlight.get(book.id)
  if (pending) return pending

  const promise = (async (): Promise<string | null> => {
    let bytes: number[] = book.cover
    if (bytes.length === 0) {
      // List query no longer ships the BLOB — pull it lazily.
      const fetched = await getCover(book.id)
      bytes = fetched ?? []
    }
    const url = bytesToBlobUrl(bytes)
    if (!url) {
      // Cache a stable null so we don't refetch on every remount for books
      // that genuinely have no cover. The Map entry's mere presence is the
      // negative cache; we still represent "no cover" as the absence of a
      // string URL, so callers see null without retrying.
      return null
    }
    coverUrlCache.set(book.id, url)
    const preload = new Image()
    preload.src = url
    void preload.decode().catch(() => {})
    coverImageCache.set(book.id, preload)
    return url
  })().finally(() => {
    coverFetchInFlight.delete(book.id)
  })

  coverFetchInFlight.set(book.id, promise)
  return promise
}

/**
 * Release a single entry. Call this on delete, OR after a mutation that
 * rewrites the underlying cover bytes (e.g. the PDF page-1 capture in
 * updateStoredCoverImage) — otherwise the cached blob URL keeps serving
 * the old placeholder until full reload.
 */
export function revokeCachedCoverUrl(bookId: number): void {
  const url = coverUrlCache.get(bookId)
  if (url) {
    URL.revokeObjectURL(url)
    coverUrlCache.delete(bookId)
  }
  coverImageCache.delete(bookId)
  coverFetchInFlight.delete(bookId)
}
