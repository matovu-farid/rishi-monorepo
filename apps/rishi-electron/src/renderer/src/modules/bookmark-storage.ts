/**
 * Bookmark storage module using typed Electron IPC handlers backed by Drizzle ORM.
 */

export interface BookmarkRow {
  id: string
  bookId: string
  location: string
  label: string
  pageNumber: number | null
  createdAt: number
  updatedAt: number
  syncVersion: number
  isDirty: number
  isDeleted: number
}

/**
 * Extract the spine prefix from an EPUB CFI for fuzzy matching.
 * e.g. "epubcfi(/6/8!/4/2/2)" -> "epubcfi(/6/8!"
 */
export function getSpinePrefix(location: string): string | null {
  if (!location.startsWith('epubcfi(')) return null
  const bangIndex = location.indexOf('!')
  if (bangIndex === -1) return null
  return location.slice(0, bangIndex + 1)
}

export function locationsMatch(a: string, b: string): boolean {
  const prefixA = getSpinePrefix(a)
  const prefixB = getSpinePrefix(b)
  if (prefixA && prefixB) {
    return prefixA === prefixB
  }
  return a === b
}

export async function getBookmarksForBook(bookSyncId: string): Promise<BookmarkRow[]> {
  return window.electron.bookmarksList(bookSyncId)
}

/**
 * Fetch the current bookmark list for a book and publish a summary into the
 * native menu context so the Bookmarks > recent submenu (book windows) shows
 * up to 10 most-recent jumps. Safe to call repeatedly: noop on missing
 * bookSyncId or absent preload bridge (test envs).
 */
export async function publishBookmarksToMenu(bookSyncId: string): Promise<void> {
  if (!bookSyncId) return
  const e = (
    window as unknown as {
      electron?: {
        bookmarksList(id: string): Promise<BookmarkRow[]>
        setMenuContext(p: Record<string, unknown>): void
      }
    }
  ).electron
  if (!e) return
  try {
    const rows = await e.bookmarksList(bookSyncId)
    const summary = rows
      .filter((b) => b.isDeleted === 0)
      .map((b) => ({
        id: b.id,
        label: b.label && b.label.length > 0 ? b.label : `Page ${b.location}`,
        location: b.location
      }))
    e.setMenuContext({ bookmarks: summary })
  } catch (err) {
    console.warn('[menu] publishBookmarksToMenu failed:', err)
  }
}

export async function saveBookmark(params: {
  bookId: string
  location: string
  label?: string
}): Promise<string> {
  const id = crypto.randomUUID()
  await window.electron.bookmarksSave({
    id,
    bookId: params.bookId,
    location: params.location,
    label: params.label ?? ''
  })
  return id
}

export async function deleteBookmark(bookmarkId: string): Promise<void> {
  await window.electron.bookmarksDelete(bookmarkId)
}

export async function toggleBookmark(params: {
  bookSyncId: string
  location: string
  label?: string
}): Promise<{ action: 'created' | 'deleted' }> {
  const allBookmarks = await getBookmarksForBook(params.bookSyncId)
  const matching = allBookmarks.filter((b) => locationsMatch(b.location, params.location))

  if (matching.length > 0) {
    // Each delete targets a different row id; safe to run in parallel.
    await Promise.all(matching.map((bookmark) => deleteBookmark(bookmark.id)))
    return { action: 'deleted' }
  }

  await saveBookmark({ bookId: params.bookSyncId, location: params.location, label: params.label })
  return { action: 'created' }
}
