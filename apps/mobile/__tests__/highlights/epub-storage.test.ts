/**
 * CG11 — Direct unit tests for the EPUB highlight CRUD path through
 * `lib/highlight-storage.ts`. Mirrors the existing PDF coverage in
 * `__tests__/pdf/highlights.test.ts` but exercises the EPUB-shaped
 * `cfiRange` (an `epubcfi(...)` string) instead of a `pdf:`-prefixed
 * JSON locator.
 *
 * EPUB highlights and PDF highlights share the same SQLite `highlights`
 * table and the same CRUD functions (`insertHighlight`,
 * `getHighlightsByBookId`, `updateHighlight`, `deleteHighlight`,
 * `restoreHighlight`). The split is purely in the `cfiRange` column
 * encoding — see `packages/shared/src/types/pdf-locator.ts`.
 */

jest.mock('expo-crypto', () => {
  let counter = 0
  return {
    randomUUID: () => `epub-uuid-${++counter}`,
  }
})

jest.mock('@/lib/db', () => {
  const rows: Array<Record<string, unknown>> = []
  const collect = { rows }
  return {
    db: {
      insert: () => ({
        values: (vals: Record<string, unknown>) => ({
          run: () => {
            collect.rows.push(vals)
          },
        }),
      }),
      select: () => ({
        from: () => ({
          where: () => ({
            orderBy: () => ({
              all: () => collect.rows.filter((r) => !r.isDeleted),
            }),
          }),
        }),
      }),
      update: () => ({
        set: (updates: Record<string, unknown>) => ({
          where: () => ({
            run: () => {
              // Mirrors the PDF-highlight mock: apply updates to every row
              // whose id matches the implicit where clause. Tests set up
              // single-row scenarios so this is unambiguous.
              for (const r of collect.rows) {
                if (
                  typeof updates.id === 'undefined' ||
                  r.id === updates.id ||
                  (updates as { __filterId?: string }).__filterId === r.id
                ) {
                  Object.assign(r, updates)
                }
              }
            },
          }),
        }),
      }),
      __rows: collect.rows,
      __reset: () => {
        collect.rows.length = 0
      },
    },
  }
})

const mockTriggerSyncOnWrite = jest.fn()
jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: mockTriggerSyncOnWrite,
}))

import {
  insertHighlight,
  getHighlightsByBookId,
  updateHighlight,
  deleteHighlight,
  restoreHighlight,
} from '@/lib/highlight-storage'
import { db } from '@/lib/db'
import { isPdfCfiRange } from '@rishi/shared/types/pdf-locator'

const SAMPLE_EPUB_CFI = 'epubcfi(/6/4!/4/2,/1:0,/1:34)'

describe('EPUB highlight CRUD via lib/highlight-storage (CG11)', () => {
  beforeEach(() => {
    ;(db as unknown as { __reset(): void }).__reset()
    mockTriggerSyncOnWrite.mockClear()
  })

  it('insertHighlight stores an epubcfi row and survives a getHighlightsByBookId roundtrip', () => {
    const h = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 'a quoted passage',
      color: 'yellow',
      chapter: 'Chapter 1',
    })

    // The row carries the raw epubcfi — NOT the `pdf:` prefix.
    expect(h.cfiRange).toBe(SAMPLE_EPUB_CFI)
    expect(isPdfCfiRange(h.cfiRange)).toBe(false)

    const rows = getHighlightsByBookId('book-epub-1')
    expect(rows).toHaveLength(1)
    expect(rows[0].id).toBe(h.id)
    expect(rows[0].text).toBe('a quoted passage')
    expect(rows[0].cfiRange).toBe(SAMPLE_EPUB_CFI)
    expect(rows[0].chapter).toBe('Chapter 1')
  })

  it('insertHighlight defaults note and chapter to null when omitted', () => {
    const h = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 't',
      color: 'green',
    })
    expect(h.note).toBeNull()
    expect(h.chapter).toBeNull()
  })

  it('insertHighlight generates a unique id per call', () => {
    const a = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 'one',
      color: 'yellow',
    })
    const b = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: 'epubcfi(/6/4!/4/4,/1:0,/1:10)',
      text: 'two',
      color: 'green',
    })
    expect(a.id).not.toBe(b.id)
  })

  it('getHighlightsByBookId returns the EPUB row alongside PDF rows in the same book', () => {
    // Mix one EPUB and one PDF-shaped row directly so we prove the
    // shared CRUD reader doesn't filter EPUB rows.
    insertHighlight({
      bookId: 'book-mixed-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 'epub row',
      color: 'yellow',
    })
    ;(db as unknown as { __rows: Array<Record<string, unknown>> }).__rows.push({
      id: 'pdf-row-1',
      bookId: 'book-mixed-1',
      cfiRange: 'pdf:{"page":3,"rects":[{"x":1,"y":2,"w":3,"h":4}]}',
      text: 'pdf row',
      color: 'green',
      note: null,
      chapter: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      isDeleted: false,
    })
    const rows = getHighlightsByBookId('book-mixed-1')
    // The generic reader returns both rows — only `getPdfHighlightsByBookId`
    // filters by the `pdf:` prefix.
    expect(rows).toHaveLength(2)
  })

  it('updateHighlight changes color + note on the EPUB row', () => {
    const h = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 'hi',
      color: 'yellow',
    })
    updateHighlight(h.id, { color: 'pink', note: 'first note' })
    const row = (db as unknown as { __rows: Array<{ id: string; color: string; note: string | null }> }).__rows.find(
      (r) => r.id === h.id,
    )
    expect(row?.color).toBe('pink')
    expect(row?.note).toBe('first note')
  })

  it('deleteHighlight soft-deletes the EPUB row (isDeleted=true, kept in table)', () => {
    const h = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 'hi',
      color: 'yellow',
    })
    deleteHighlight(h.id)

    // The row is still physically present (sync needs to see the deletion),
    // but `getHighlightsByBookId` filters it out.
    expect(getHighlightsByBookId('book-epub-1')).toHaveLength(0)
    const raw = (db as unknown as { __rows: Array<{ id: string; isDeleted: boolean }> }).__rows.find(
      (r) => r.id === h.id,
    )
    expect(raw?.isDeleted).toBe(true)
  })

  it('restoreHighlight flips isDeleted back to false (Undo-snackbar wiring)', () => {
    const h = insertHighlight({
      bookId: 'book-epub-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 'hi',
      color: 'yellow',
    })
    deleteHighlight(h.id)
    expect(getHighlightsByBookId('book-epub-1')).toHaveLength(0)

    restoreHighlight(h.id)
    const restored = getHighlightsByBookId('book-epub-1')
    expect(restored).toHaveLength(1)
    expect(restored[0].id).toBe(h.id)
    // The row's text/color/note/chapter survive the soft-delete cycle.
    expect(restored[0].text).toBe('hi')
    expect(restored[0].color).toBe('yellow')
  })
})

// ── CG12 — triggerSyncOnWrite called by every EPUB CRUD entry point ─────────
//
// Per audit CG12 (Phase A quick-win): every write that mutates the
// `highlights` table must call `triggerSyncOnWrite` exactly once so the
// row reaches D1 on the next push. The conversation-storage tests
// already pin this for conversation/message writes; we extend the
// pattern here for the EPUB highlight CRUD entry points.
describe('CG12 — triggerSyncOnWrite called by EPUB highlight CRUD', () => {
  beforeEach(() => {
    ;(db as unknown as { __reset(): void }).__reset()
    mockTriggerSyncOnWrite.mockClear()
  })

  it('insertHighlight calls triggerSyncOnWrite exactly once', () => {
    insertHighlight({
      bookId: 'book-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 't',
      color: 'yellow',
    })
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('updateHighlight calls triggerSyncOnWrite exactly once', () => {
    const h = insertHighlight({
      bookId: 'book-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 't',
      color: 'yellow',
    })
    mockTriggerSyncOnWrite.mockClear()
    updateHighlight(h.id, { color: 'pink' })
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('deleteHighlight calls triggerSyncOnWrite exactly once', () => {
    const h = insertHighlight({
      bookId: 'book-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 't',
      color: 'yellow',
    })
    mockTriggerSyncOnWrite.mockClear()
    deleteHighlight(h.id)
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('restoreHighlight calls triggerSyncOnWrite exactly once', () => {
    const h = insertHighlight({
      bookId: 'book-1',
      cfiRange: SAMPLE_EPUB_CFI,
      text: 't',
      color: 'yellow',
    })
    deleteHighlight(h.id)
    mockTriggerSyncOnWrite.mockClear()
    restoreHighlight(h.id)
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })
})
