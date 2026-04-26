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
    for (const bookmark of matching) {
      await deleteBookmark(bookmark.id)
    }
    return { action: 'deleted' }
  }

  await saveBookmark({ bookId: params.bookSyncId, location: params.location, label: params.label })
  return { action: 'created' }
}
