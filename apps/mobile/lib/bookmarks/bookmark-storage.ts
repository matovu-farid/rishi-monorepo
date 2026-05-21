/**
 * Mobile bookmark CRUD module — ports the public surface of electron's
 * `apps/rishi-electron/src/renderer/src/modules/bookmark-storage.ts` while
 * swapping the IPC layer for direct Drizzle calls (matches the mobile
 * highlight-storage pattern).
 *
 * Bookmarks live in the shared `bookmarks` table (see
 * `@rishi/shared/schema.bookmarks`) and sync via the same dirty-flag /
 * sync-version pipeline as books / highlights / conversations.
 */
import * as Crypto from 'expo-crypto'
import { eq, and, desc } from 'drizzle-orm'
import { db } from '@/lib/db'
import { bookmarks } from '@rishi/shared/schema'
import {
  getSpinePrefix,
  locationsMatch,
  type BookmarkRow,
} from '@rishi/shared/formats/bookmark-cfi'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'

// Re-export so callers can `import { ... } from '@/lib/bookmarks/bookmark-storage'`
// without reaching into shared themselves.
export { getSpinePrefix, locationsMatch }
export type { BookmarkRow }

/**
 * UI-friendly bookmark projection. Strips sync metadata that the reader
 * UI never needs.
 */
export interface Bookmark {
  id: string
  bookId: string
  location: string
  label: string
  pageNumber: number | null
  createdAt: number
  updatedAt: number
}

function mapRow(row: typeof bookmarks.$inferSelect): Bookmark {
  return {
    id: row.id,
    bookId: row.bookId,
    location: row.location,
    label: row.label,
    pageNumber: row.pageNumber,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  }
}

/**
 * Insert a new bookmark. Mirrors electron's `saveBookmark` plus the
 * mobile-side trigger / dirty-flag wiring.
 */
export function insertBookmark(params: {
  bookId: string
  location: string
  label?: string
  pageNumber?: number | null
}): Bookmark {
  const now = Date.now()
  const id = Crypto.randomUUID()
  const label = params.label ?? ''
  const pageNumber = params.pageNumber ?? null

  db.insert(bookmarks)
    .values({
      id,
      bookId: params.bookId,
      location: params.location,
      label,
      pageNumber,
      createdAt: now,
      updatedAt: now,
      isDirty: true,
      isDeleted: false,
    })
    .run()

  triggerSyncOnWrite()

  return {
    id,
    bookId: params.bookId,
    location: params.location,
    label,
    pageNumber,
    createdAt: now,
    updatedAt: now,
  }
}

/** Fetch all non-deleted bookmarks for a book, most recent first. */
export function getBookmarksForBook(bookId: string): Bookmark[] {
  const rows = db
    .select()
    .from(bookmarks)
    .where(and(eq(bookmarks.bookId, bookId), eq(bookmarks.isDeleted, false)))
    .orderBy(desc(bookmarks.createdAt))
    .all()
  return rows.map(mapRow)
}

/**
 * Soft-delete a bookmark. Sets isDeleted, bumps updatedAt, marks dirty
 * for sync.
 */
export function deleteBookmark(id: string): void {
  db.update(bookmarks)
    .set({
      isDeleted: true,
      updatedAt: Date.now(),
      isDirty: true,
    })
    .where(eq(bookmarks.id, id))
    .run()

  triggerSyncOnWrite()
}

/**
 * Toggle bookmark for a CFI. If any non-deleted bookmark with a
 * location whose spine prefix matches `params.location` exists, delete
 * all of them; otherwise insert a new bookmark at `params.location`.
 *
 * Returns `{ action: 'created' | 'deleted' }` matching electron's API
 * so the EPUB reader can show the right confirmation toast.
 */
export function toggleBookmark(params: {
  bookId: string
  location: string
  label?: string
  pageNumber?: number | null
}): { action: 'created' | 'deleted'; bookmark?: Bookmark } {
  const existing = getBookmarksForBook(params.bookId).filter((b) =>
    locationsMatch(b.location, params.location),
  )

  if (existing.length > 0) {
    for (const bm of existing) deleteBookmark(bm.id)
    return { action: 'deleted' }
  }

  const inserted = insertBookmark(params)
  return { action: 'created', bookmark: inserted }
}

/**
 * Convenience: returns true if any non-deleted bookmark exists at
 * `location` (fuzzy match via spine prefix). Use in the toolbar so the
 * Bookmark icon can render filled when the current CFI is bookmarked.
 */
export function isLocationBookmarked(bookId: string, location: string): boolean {
  return getBookmarksForBook(bookId).some((b) => locationsMatch(b.location, location))
}
