import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'

vi.mock('@/modules/highlight-storage', () => ({
  getHighlightsForBook: vi.fn().mockResolvedValue([])
}))

const deleteHighlightWithUndoMock = vi.fn(async (args: unknown) => {
  // Capture the call so each test can assert on it.
  ;(deleteHighlightWithUndoMock as unknown as { lastArgs: unknown }).lastArgs = args
  return { undo: vi.fn() }
})

vi.mock('@/modules/highlight-actions', () => ({
  deleteHighlightWithUndo: (args: unknown) => deleteHighlightWithUndoMock(args)
}))

const highlightRangeMock = vi.fn().mockResolvedValue(undefined)
const removeHighlightMock = vi.fn().mockResolvedValue(undefined)

vi.mock('@/modules/epubwrapper', () => ({
  highlightRange: (...args: unknown[]) => highlightRangeMock(...args),
  removeHighlight: (...args: unknown[]) => removeHighlightMock(...args)
}))

vi.mock('sonner', () => ({ toast: vi.fn() }))

import { getHighlightsForBook, type HighlightRow } from '@/modules/highlight-storage'
import { HighlightsPanel } from './HighlightsPanel'
import { NOTE_COLOR_NONE } from '@/types/highlight'

function row(over: Partial<HighlightRow> = {}): HighlightRow {
  return {
    id: 'row-1',
    bookId: 'book-1',
    cfiRange: 'cfi:1',
    text: 'the quick brown fox',
    color: 'yellow',
    note: '',
    chapter: null,
    createdAt: '0',
    updatedAt: 0,
    syncId: null,
    syncVersion: 0,
    isDirty: 1,
    isDeleted: 0,
    ...over
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('HighlightsPanel — note-only support', () => {
  it("renders a distinct (non-transparent, non-highlight-color) border strip for a note-only row so users can tell them apart from colored highlights", async () => {
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      row({ id: 'note-only', color: NOTE_COLOR_NONE, note: 'a thought' })
    ])

    render(
      <HighlightsPanel
        bookSyncId="book-1"
        rendition={{} as never}
        open
        onOpenChange={vi.fn()}
        setLastUndoable={vi.fn()}
        makeAnnotationClickCb={vi.fn(() => () => undefined)}
      />
    )

    await waitFor(() => expect(screen.getByText('the quick brown fox')).toBeInTheDocument())
    const card = screen.getByText('the quick brown fox').closest('div[style]') as HTMLElement
    // Note-only rows need a visible affordance — Apple Books uses a distinct
    // marker. A transparent border (the naive `getHighlightHex('none')`
    // fallback) makes them indistinguishable from a layout glitch.
    expect(card.style.borderLeft).not.toMatch(/transparent/)
    expect(card.style.borderLeft).not.toMatch(/#FBBF24/i) // not yellow either
  })

  it('renders the colored border strip for a normal colored highlight (regression guard)', async () => {
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      row({ id: 'colored', color: 'yellow' })
    ])

    render(
      <HighlightsPanel
        bookSyncId="book-1"
        rendition={{} as never}
        open
        onOpenChange={vi.fn()}
        setLastUndoable={vi.fn()}
        makeAnnotationClickCb={vi.fn(() => () => undefined)}
      />
    )

    await waitFor(() => expect(screen.getByText('the quick brown fox')).toBeInTheDocument())
    const card = screen.getByText('the quick brown fox').closest('div[style]') as HTMLElement
    expect(card.style.borderLeft).toMatch(/#FBBF24/i)
  })

  it('deleting a note-only row passes a no-op applyVisual (no highlightRange re-draw on undo)', async () => {
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      row({ id: 'note-only', color: NOTE_COLOR_NONE, note: 'a thought' })
    ])

    render(
      <HighlightsPanel
        bookSyncId="book-1"
        rendition={{} as never}
        open
        onOpenChange={vi.fn()}
        setLastUndoable={vi.fn()}
        makeAnnotationClickCb={vi.fn(() => () => undefined)}
      />
    )

    const card = await screen.findByText('the quick brown fox')
    fireEvent.mouseEnter(card.parentElement!)
    fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))

    await waitFor(() => expect(deleteHighlightWithUndoMock).toHaveBeenCalledTimes(1))
    const args = (deleteHighlightWithUndoMock as unknown as { lastArgs: { target: { applyVisual: () => Promise<void> } } }).lastArgs
    await args.target.applyVisual()
    // The note-only row has no SVG mark to restore — applyVisual must be a
    // pure no-op that never calls into epubjs.
    expect(highlightRangeMock).not.toHaveBeenCalled()
  })

  it('deleting a colored highlight still calls highlightRange on undo (regression guard)', async () => {
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      row({ id: 'colored', color: 'green' })
    ])

    render(
      <HighlightsPanel
        bookSyncId="book-1"
        rendition={{} as never}
        open
        onOpenChange={vi.fn()}
        setLastUndoable={vi.fn()}
        makeAnnotationClickCb={vi.fn(() => () => undefined)}
      />
    )

    const card = await screen.findByText('the quick brown fox')
    fireEvent.mouseEnter(card.parentElement!)
    fireEvent.click(screen.getByRole('button', { name: /delete highlight/i }))

    await waitFor(() => expect(deleteHighlightWithUndoMock).toHaveBeenCalledTimes(1))
    const args = (deleteHighlightWithUndoMock as unknown as { lastArgs: { target: { applyVisual: () => Promise<void> } } }).lastArgs
    await args.target.applyVisual()
    expect(highlightRangeMock).toHaveBeenCalledTimes(1)
  })
})
