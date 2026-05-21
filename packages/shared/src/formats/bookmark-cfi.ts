/**
 * Bookmark CFI parsing primitives extracted from electron's
 * apps/rishi-electron/src/renderer/src/modules/bookmark-storage.ts
 * (lines 1-36). Only the row-shape type and pure CFI helpers — the rest
 * of the source file wraps `window.electron.*` IPC and stays in
 * electron.
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
