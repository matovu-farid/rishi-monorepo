import { usePdfStore, BookNavigationState } from '@/lib/stores/pdfStore'

const initialState = usePdfStore.getState()

function reset(): void {
  usePdfStore.setState(initialState, true)
}

describe('pdfStore', () => {
  beforeEach(reset)

  it('starts with idle navigation and zeroed page state', () => {
    const s = usePdfStore.getState()
    expect(s.pageNumber).toBe(0)
    expect(s.pageCount).toBe(0)
    expect(s.outline).toEqual([])
    expect(s.bookNavigationState).toBe(BookNavigationState.Idle)
  })

  it('setPageNumber from Idle transitions to Navigating', () => {
    usePdfStore.getState().setPageNumber(10)
    const s = usePdfStore.getState()
    expect(s.pageNumber).toBe(10)
    expect(s.bookNavigationState).toBe(BookNavigationState.Navigating)
  })

  it('setPageNumber while Navigating is a no-op (matches electron seek lockout)', () => {
    usePdfStore.getState().setPageNumber(10)
    // Second setPageNumber should be ignored — protects against UI taps
    // landing while a seek is still in flight.
    usePdfStore.getState().setPageNumber(20)
    expect(usePdfStore.getState().pageNumber).toBe(10)
  })

  it('setScrollPageNumber updates pageNumber when not Navigating', () => {
    usePdfStore.getState().setPageCount(100)
    usePdfStore.getState().setScrollPageNumber(5)
    const s = usePdfStore.getState()
    expect(s.scrollPageNumber).toBe(5)
    expect(s.pageNumber).toBe(5)
  })

  it('setScrollPageNumber leaves pageNumber alone while Navigating', () => {
    usePdfStore.getState().setPageCount(100)
    usePdfStore.getState().setPageNumber(50) // → Navigating
    usePdfStore.getState().setScrollPageNumber(1) // scroll watcher fires "1" during seek
    const s = usePdfStore.getState()
    expect(s.scrollPageNumber).toBe(1)
    // pageNumber must NOT drop to 1 — that's the bug the lockout prevents.
    expect(s.pageNumber).toBe(50)
  })

  it('nextPage / previousPage respect bounds', () => {
    usePdfStore.getState().setPageCount(10)
    // Bypass the Idle→Navigating lock by toggling the state ourselves.
    usePdfStore.setState({ pageNumber: 5, bookNavigationState: BookNavigationState.Idle })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(6)
    // After nextPage the state is Navigating; reset back to Idle for the
    // next manipulation.
    usePdfStore.setState({ bookNavigationState: BookNavigationState.Idle })
    usePdfStore.getState().previousPage()
    expect(usePdfStore.getState().pageNumber).toBe(5)
  })

  it('changePage clamps to [1, pageCount]', () => {
    usePdfStore.getState().setPageCount(5)
    usePdfStore.setState({ pageNumber: 1, bookNavigationState: BookNavigationState.Idle })
    usePdfStore.getState().previousPage() // would go to 0, should no-op
    expect(usePdfStore.getState().pageNumber).toBe(1)

    usePdfStore.setState({ pageNumber: 5, bookNavigationState: BookNavigationState.Idle })
    usePdfStore.getState().nextPage() // would go to 6, should no-op
    expect(usePdfStore.getState().pageNumber).toBe(5)
  })

  it('setOutline replaces the outline', () => {
    const outline = [{ title: 'Chapter 1', pageNumber: 1, children: [] }]
    usePdfStore.getState().setOutline(outline)
    expect(usePdfStore.getState().outline).toEqual(outline)
  })

  it('setCurrentParagraph + highlightedParagraphIndex flow', () => {
    usePdfStore.getState().setCurrentParagraph({ index: '10001', text: 'hi' })
    usePdfStore.getState().setHighlightedParagraphIndex('10001')
    usePdfStore.getState().setIsHighlighting(true)
    const s = usePdfStore.getState()
    expect(s.currentParagraph.index).toBe('10001')
    expect(s.highlightedParagraphIndex).toBe('10001')
    expect(s.isHighlighting).toBe(true)
  })

  it('resetParagraphState wipes pageCount, outline, and highlight bookkeeping', () => {
    usePdfStore.getState().setPageCount(100)
    usePdfStore.getState().setOutline([{ title: 'X', pageNumber: 1, children: [] }])
    usePdfStore.getState().setHighlightedParagraphIndex('10001')
    usePdfStore.getState().setIsHighlighting(true)
    usePdfStore.getState().setCurrentParagraph({ index: '10001', text: 'hi' })
    usePdfStore.getState().resetParagraphState()
    const s = usePdfStore.getState()
    expect(s.pageCount).toBe(0)
    expect(s.outline).toEqual([])
    expect(s.highlightedParagraphIndex).toBe('')
    expect(s.isHighlighting).toBe(false)
    expect(s.currentParagraph).toEqual({ index: '', text: '' })
    expect(s.bookNavigationState).toBe(BookNavigationState.Idle)
  })
})
