/**
 * Highlight undo test (G10 polish).
 *
 * Verifies that `restoreHighlight(id)` flips a previously soft-deleted
 * row back to active (`isDeleted = false`) and marks it dirty for the
 * next sync pass.
 */

jest.mock('expo-crypto', () => {
  let counter = 0
  return {
    randomUUID: () => `h-uuid-${++counter}`,
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
          where: () => ({
            run: () => {
              for (const r of rows) Object.assign(r, updates)
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
  insertHighlight,
  deleteHighlight,
  restoreHighlight,
} from '@/lib/highlight-storage'
import { db } from '@/lib/db'

interface MockDb {
  __rows: Array<Record<string, unknown>>
  __reset(): void
}

describe('restoreHighlight (undo)', () => {
  beforeEach(() => {
    ;(db as unknown as MockDb).__reset()
  })

  it('flips isDeleted back to false', () => {
    const h = insertHighlight({
      bookId: 'book-1',
      cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
      text: 'sample',
      color: 'yellow',
    })
    deleteHighlight(h.id)
    const after = (db as unknown as MockDb).__rows.find((r) => r.id === h.id)
    expect(after?.isDeleted).toBe(true)
    restoreHighlight(h.id)
    const restored = (db as unknown as MockDb).__rows.find((r) => r.id === h.id)
    expect(restored?.isDeleted).toBe(false)
    expect(restored?.isDirty).toBe(true)
  })

  it('bumps updatedAt on restore', () => {
    const h = insertHighlight({
      bookId: 'book-1',
      cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
      text: 'sample',
      color: 'yellow',
    })
    deleteHighlight(h.id)
    const t1 = (db as unknown as MockDb).__rows.find((r) => r.id === h.id)
      ?.updatedAt as number
    restoreHighlight(h.id)
    const t2 = (db as unknown as MockDb).__rows.find((r) => r.id === h.id)
      ?.updatedAt as number
    expect(t2).toBeGreaterThanOrEqual(t1)
  })
})
