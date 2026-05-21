/**
 * NoteEditor type-widening test (Batch 5 deferred → Batch 7 Phase 9).
 *
 * The NoteEditor prop type used to require a full EPUB `Highlight`
 * (from `@/types/highlight`). Batch 7 widened it to `NoteEditableHighlight`
 * — a structural interface with just `{ id, text, note }`. This lets the
 * PDF reader pass its `PdfHighlight` row to the same component.
 *
 * This test guards the contract: both shapes (EPUB Highlight, PDF
 * PdfHighlight) assign cleanly to `NoteEditableHighlight`. If a future
 * refactor narrows the prop again, the assignment fails at compile time
 * and this test stops typechecking.
 *
 * Test runs as a pure type assertion + a smoke `note-or-null` check.
 */
import type { NoteEditableHighlight } from '@/components/NoteEditor'
import type { Highlight } from '@/types/highlight'
import type { PdfHighlight } from '@/lib/highlight-storage'

describe('NoteEditableHighlight widening', () => {
  it('EPUB Highlight is assignable to NoteEditableHighlight', () => {
    const epub: Highlight = {
      id: 'h-1',
      bookId: 'b',
      cfiRange: 'epubcfi(/6/4)',
      text: 'hello',
      color: 'yellow',
      note: null,
      chapter: null,
      createdAt: 0,
      updatedAt: 0,
    }
    const widened: NoteEditableHighlight = epub
    expect(widened.id).toBe('h-1')
    expect(widened.text).toBe('hello')
  })

  it('PdfHighlight is assignable to NoteEditableHighlight', () => {
    const pdf: PdfHighlight = {
      id: 'p-1',
      bookId: 'b',
      cfiRange: 'pdf:{}',
      locator: { page: 1, rects: [] },
      text: 'pdf snippet',
      color: 'green',
      note: 'my note',
      chapter: null,
      createdAt: 0,
      updatedAt: 0,
    }
    const widened: NoteEditableHighlight = pdf
    expect(widened.id).toBe('p-1')
    expect(widened.text).toBe('pdf snippet')
    expect(widened.note).toBe('my note')
  })

  it('null note is allowed', () => {
    const widened: NoteEditableHighlight = {
      id: 'x',
      text: 'hi',
      note: null,
    }
    expect(widened.note).toBeNull()
  })
})
