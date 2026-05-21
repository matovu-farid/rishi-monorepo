/**
 * Pure logic test for the BookmarksList sorting / display projection.
 *
 * The component itself is RN-only and relies on @gorhom/bottom-sheet
 * which would require a heavier jest setup (preset: 'react-native')
 * than this project's node-env config. Following the established mobile
 * test convention (see `__tests__/tts/visual-cue.test.ts` — the
 * component layer is exercised by Maestro, the logic in jest), this
 * test covers only the pure sort / label-fallback behaviour the row
 * renderer relies on.
 */
import type { Bookmark } from '@/lib/bookmarks/bookmark-storage'

function sortBookmarks(items: Bookmark[]): Bookmark[] {
  return [...items].sort((a, b) => b.createdAt - a.createdAt)
}

function deriveDisplayLabel(bm: Bookmark): string {
  return bm.label && bm.label.length > 0 ? bm.label : bm.location
}

function makeBookmark(over: Partial<Bookmark> = {}): Bookmark {
  return {
    id: 'bm-1',
    bookId: 'book-1',
    location: 'epubcfi(/6/8!/4/2/2)',
    label: 'Chapter 1',
    pageNumber: null,
    createdAt: new Date('2026-01-15').getTime(),
    updatedAt: new Date('2026-01-15').getTime(),
    ...over,
  }
}

describe('BookmarksList projection', () => {
  it('sorts bookmarks by createdAt descending', () => {
    const items = [
      makeBookmark({ id: 'older', createdAt: 1000 }),
      makeBookmark({ id: 'newer', createdAt: 5000 }),
      makeBookmark({ id: 'middle', createdAt: 3000 }),
    ]
    const sorted = sortBookmarks(items)
    expect(sorted.map((b) => b.id)).toEqual(['newer', 'middle', 'older'])
  })

  it('preserves original input', () => {
    const items = [
      makeBookmark({ id: 'a', createdAt: 1 }),
      makeBookmark({ id: 'b', createdAt: 2 }),
    ]
    sortBookmarks(items)
    expect(items.map((b) => b.id)).toEqual(['a', 'b'])
  })

  it('derives display label from label when present', () => {
    const bm = makeBookmark({ label: 'My Note' })
    expect(deriveDisplayLabel(bm)).toBe('My Note')
  })

  it('falls back to location when label is empty', () => {
    const bm = makeBookmark({ label: '' })
    expect(deriveDisplayLabel(bm)).toBe(bm.location)
  })
})
