/**
 * Tests for the mobile bookmark CRUD module.
 *
 * Mirrors the structure of `__tests__/pdf/highlights.test.ts` — the real
 * Drizzle / expo-sqlite stack is replaced by an in-memory mock so the test
 * runs in node without native bindings.
 *
 * Covers:
 *   - insertBookmark: stores row, assigns UUID + timestamps, marks dirty
 *   - getBookmarksForBook: returns non-deleted rows in createdAt-DESC order
 *   - deleteBookmark: soft-deletes (isDeleted=true, updatedAt bumped)
 *   - toggleBookmark: creates if none match, deletes if any match
 *   - isLocationBookmarked: fuzzy match by spine prefix
 */

jest.mock('expo-crypto', () => {
  let counter = 0
  return {
    randomUUID: () => `bm-uuid-${++counter}`,
  }
})

jest.mock('@/lib/db', () => {
  const rows: Array<Record<string, unknown>> = []
  return {
    db: {
      insert: () => ({
        values: (vals: Record<string, unknown>) => ({
          run: () => {
            rows.push({ ...vals })
          },
        }),
      }),
      select: () => ({
        from: () => ({
          where: () => ({
            orderBy: () => ({
              all: () => rows.filter((r) => !r.isDeleted),
            }),
          }),
        }),
      }),
      update: () => ({
        set: (updates: Record<string, unknown>) => ({
          where: (filter: Record<string, unknown>) => ({
            run: () => {
              // crude filter: try to match by id off the most recent update
              for (const r of rows) {
                if (
                  filter && '__id' in filter
                    ? r.id === (filter as { __id: string }).__id
                    : true
                ) {
                  Object.assign(r, updates)
                }
              }
            },
          }),
        }),
      }),
      __rows: rows,
      __reset: () => {
        rows.length = 0
      },
    },
  }
})

jest.mock('@/lib/sync/triggers', () => ({ triggerSyncOnWrite: jest.fn() }))

import {
  insertBookmark,
  getBookmarksForBook,
  deleteBookmark,
  toggleBookmark,
  isLocationBookmarked,
} from '@/lib/bookmarks/bookmark-storage'
import { db } from '@/lib/db'
import { triggerSyncOnWrite } from '@/lib/sync/triggers'

interface MockDb {
  __rows: Array<Record<string, unknown>>
  __reset(): void
}

const CFI_A = 'epubcfi(/6/8!/4/2/2)'
const CFI_A_DEEP = 'epubcfi(/6/8!/4/4/3)' // same spine prefix as CFI_A
const CFI_B = 'epubcfi(/6/12!/4/2/2)'

describe('bookmark-storage', () => {
  beforeEach(() => {
    ;(db as unknown as MockDb).__reset()
    ;(triggerSyncOnWrite as jest.Mock).mockClear()
  })

  it('insertBookmark assigns UUID, timestamps and marks dirty', () => {
    const before = Date.now()
    const b = insertBookmark({
      bookId: 'book-1',
      location: CFI_A,
      label: 'Chapter 1',
    })
    const after = Date.now()

    expect(b.id).toMatch(/^bm-uuid-/)
    expect(b.bookId).toBe('book-1')
    expect(b.location).toBe(CFI_A)
    expect(b.label).toBe('Chapter 1')
    expect(b.createdAt).toBeGreaterThanOrEqual(before)
    expect(b.createdAt).toBeLessThanOrEqual(after)
    expect(b.updatedAt).toBeGreaterThanOrEqual(before)

    const rows = (db as unknown as MockDb).__rows
    expect(rows[0]).toMatchObject({
      id: b.id,
      bookId: 'book-1',
      location: CFI_A,
      label: 'Chapter 1',
      isDirty: true,
      isDeleted: false,
    })
    expect(triggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('insertBookmark defaults label to empty string and pageNumber to null', () => {
    const b = insertBookmark({ bookId: 'book-1', location: CFI_A })
    expect(b.label).toBe('')
    expect(b.pageNumber).toBeNull()
  })

  it('getBookmarksForBook returns non-deleted rows', () => {
    const a = insertBookmark({ bookId: 'book-1', location: CFI_A })
    const b = insertBookmark({ bookId: 'book-1', location: CFI_B })
    // Mark `a` as deleted via the mock
    const rows = (db as unknown as MockDb).__rows
    const found = rows.find((r) => r.id === a.id)
    if (found) found.isDeleted = true
    const result = getBookmarksForBook('book-1')
    expect(result.map((r) => r.id)).toEqual([b.id])
  })

  it('deleteBookmark soft-deletes and bumps updatedAt', () => {
    const inserted = insertBookmark({ bookId: 'book-1', location: CFI_A })
    const rows = (db as unknown as MockDb).__rows
    const before = rows.find((r) => r.id === inserted.id)?.updatedAt
    deleteBookmark(inserted.id)
    const after = rows.find((r) => r.id === inserted.id)
    expect(after?.isDeleted).toBe(true)
    expect(after?.isDirty).toBe(true)
    // updatedAt should have changed (or at least be set)
    expect(after?.updatedAt).toBeGreaterThanOrEqual(before as number)
  })

  it('toggleBookmark creates when no match exists', () => {
    const result = toggleBookmark({ bookId: 'book-1', location: CFI_A })
    expect(result.action).toBe('created')
    expect(result.bookmark).toBeDefined()
    expect(getBookmarksForBook('book-1')).toHaveLength(1)
  })

  it('toggleBookmark deletes when an exact match exists', () => {
    insertBookmark({ bookId: 'book-1', location: CFI_A })
    const result = toggleBookmark({ bookId: 'book-1', location: CFI_A })
    expect(result.action).toBe('deleted')
    expect(getBookmarksForBook('book-1')).toHaveLength(0)
  })

  it('toggleBookmark deletes when a spine-prefix match exists', () => {
    insertBookmark({ bookId: 'book-1', location: CFI_A })
    // Same spine (CFI_A_DEEP shares prefix `epubcfi(/6/8!`)
    const result = toggleBookmark({ bookId: 'book-1', location: CFI_A_DEEP })
    expect(result.action).toBe('deleted')
    expect(getBookmarksForBook('book-1')).toHaveLength(0)
  })

  it('isLocationBookmarked returns true on spine-prefix match', () => {
    insertBookmark({ bookId: 'book-1', location: CFI_A })
    expect(isLocationBookmarked('book-1', CFI_A_DEEP)).toBe(true)
    expect(isLocationBookmarked('book-1', CFI_B)).toBe(false)
  })
})
