/**
 * Tests for the PDF highlight CRUD path through the shared SQLite
 * highlights table. Verifies that the pdf: cfiRange prefix
 * encode/decode round-trips and that the DB shim layer is invoked with
 * the right column values.
 *
 * The real Drizzle SQLite is replaced by a mock so tests run in node
 * without expo-sqlite native bindings.
 */

jest.mock('expo-crypto', () => {
  let counter = 0
  return {
    randomUUID: () => `mock-uuid-${++counter}`,
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
              // crude: apply updates to the most recently-touched row whose
              // id matches the where clause we'd have called. Test helpers
              // set rows up so this is unambiguous.
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
jest.mock('@/lib/sync/triggers', () => ({ triggerSyncOnWrite: mockTriggerSyncOnWrite }))

import {
  insertPdfHighlight,
  getPdfHighlightsByBookId,
  updateHighlight,
  deleteHighlight,
  restoreHighlight,
} from '@/lib/highlight-storage'
import { db } from '@/lib/db'
import { decodePdfCfiRange, isPdfCfiRange } from '@rishi/shared/types/pdf-locator'

const SAMPLE_LOCATOR = {
  page: 3,
  rects: [{ x: 72, y: 120, w: 300, h: 12 }],
}

describe('PDF highlights via cfiRange pdf: prefix', () => {
  beforeEach(() => {
    ;(db as unknown as { __reset(): void }).__reset()
  })

  it('insertPdfHighlight stores a pdf:-prefixed cfiRange that round-trips', () => {
    const h = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 'hello world',
      color: 'yellow',
    })
    expect(h.bookId).toBe('book-1')
    expect(h.text).toBe('hello world')
    expect(isPdfCfiRange(h.cfiRange)).toBe(true)
    expect(decodePdfCfiRange(h.cfiRange)).toEqual(SAMPLE_LOCATOR)
  })

  it('insertPdfHighlight generates a UUID id distinct per row', () => {
    const a = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 't1',
      color: 'yellow',
    })
    const b = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 't2',
      color: 'green',
    })
    expect(a.id).not.toBe(b.id)
    expect(a.id.length).toBeGreaterThan(8)
  })

  it('getPdfHighlightsByBookId returns only PDF rows', () => {
    // Insert one PDF and one EPUB-style row directly into the mock.
    insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 'pdf text',
      color: 'yellow',
    })
    ;(db as unknown as { __rows: Array<Record<string, unknown>> }).__rows.push({
      id: 'epub-1',
      bookId: 'book-1',
      cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
      text: 'epub text',
      color: 'green',
      note: null,
      chapter: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      isDeleted: false,
    })
    const rows = getPdfHighlightsByBookId('book-1')
    expect(rows).toHaveLength(1)
    expect(rows[0].text).toBe('pdf text')
    expect(rows[0].locator).toEqual(SAMPLE_LOCATOR)
  })

  it('updateHighlight via shared updateHighlight changes color', () => {
    const h = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 'hi',
      color: 'yellow',
    })
    updateHighlight(h.id, { color: 'pink' })
    const row = (db as unknown as { __rows: Array<{ id: string; color: string }> }).__rows.find(
      (r) => r.id === h.id
    )
    expect(row?.color).toBe('pink')
  })

  it('deleteHighlight sets isDeleted on the row', () => {
    const h = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 'hi',
      color: 'yellow',
    })
    deleteHighlight(h.id)
    const row = (db as unknown as { __rows: Array<{ id: string; isDeleted: boolean }> }).__rows.find(
      (r) => r.id === h.id
    )
    expect(row?.isDeleted).toBe(true)
  })
})

// ── CG12 — triggerSyncOnWrite is called by every PDF highlight write ────────
//
// The conversation-storage tests pin this for messages and conversations,
// but the highlight CRUD path was previously untested for the same wire-up.
// Each entry point must call `triggerSyncOnWrite` exactly once so the
// dirty row reaches D1 on the next push cycle.
describe('CG12 — triggerSyncOnWrite called by PDF highlight CRUD', () => {
  beforeEach(() => {
    ;(db as unknown as { __reset(): void }).__reset()
    mockTriggerSyncOnWrite.mockClear()
  })

  it('insertPdfHighlight calls triggerSyncOnWrite exactly once', () => {
    insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 't',
      color: 'yellow',
    })
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('deleteHighlight calls triggerSyncOnWrite exactly once for a PDF row', () => {
    const h = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 't',
      color: 'yellow',
    })
    mockTriggerSyncOnWrite.mockClear()
    deleteHighlight(h.id)
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('restoreHighlight calls triggerSyncOnWrite exactly once for a PDF row', () => {
    const h = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 't',
      color: 'yellow',
    })
    deleteHighlight(h.id)
    mockTriggerSyncOnWrite.mockClear()
    restoreHighlight(h.id)
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })

  it('updateHighlight calls triggerSyncOnWrite exactly once for a PDF row', () => {
    const h = insertPdfHighlight({
      bookId: 'book-1',
      locator: SAMPLE_LOCATOR,
      text: 't',
      color: 'yellow',
    })
    mockTriggerSyncOnWrite.mockClear()
    updateHighlight(h.id, { color: 'pink' })
    expect(mockTriggerSyncOnWrite).toHaveBeenCalledTimes(1)
  })
})
