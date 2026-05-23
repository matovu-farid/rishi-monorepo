import { describe, it, expect, beforeEach } from 'vitest'
import { usePdfStore, BookNavigationState } from './pdfStore'
import { usePrefsStore } from './prefsStore'

describe('pdfStore', () => {
  beforeEach(() => {
    // Full replace with the store's initial state so new PdfState fields
    // cannot silently leak across tests.
    usePdfStore.setState(usePdfStore.getInitialState(), true)
    // pdfFooterDetection is read by getFooterMaskForPage — keep it on by
    // default so existing tests aren't surprised by the gate.
    usePrefsStore.setState({ pdfFooterDetection: true })
  })

  it('should set page number', () => {
    usePdfStore.getState().setPageNumber(5)
    expect(usePdfStore.getState().pageNumber).toBe(5)
  })

  it('should navigate to next page', () => {
    usePdfStore.setState({
      pageNumber: 3,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(4)
  })

  it('should navigate to previous page', () => {
    usePdfStore.setState({
      pageNumber: 3,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().previousPage()
    expect(usePdfStore.getState().pageNumber).toBe(2)
  })

  it('should not go below page 1', () => {
    usePdfStore.setState({
      pageNumber: 1,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().previousPage()
    expect(usePdfStore.getState().pageNumber).toBe(1)
  })

  it('should not go above page count', () => {
    usePdfStore.setState({
      pageNumber: 10,
      pageCount: 10,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(10)
  })

  it('should handle dual page navigation', () => {
    usePdfStore.setState({
      pageNumber: 3,
      pageCount: 10,
      isDualPage: true,
      bookNavigationState: BookNavigationState.Idle
    })
    usePdfStore.getState().nextPage()
    expect(usePdfStore.getState().pageNumber).toBe(5)
  })

  it('should toggle thumbnail sidebar', () => {
    expect(usePdfStore.getState().thumbnailSidebarOpen).toBe(false)
    usePdfStore.getState().setThumbnailSidebarOpen(true)
    expect(usePdfStore.getState().thumbnailSidebarOpen).toBe(true)
  })

  it('should add and remove books', () => {
    usePdfStore.getState().addBook(1)
    usePdfStore.getState().addBook(2)
    expect(usePdfStore.getState().books).toEqual([1, 2])
    usePdfStore.getState().removeBook(1)
    expect(usePdfStore.getState().books).toEqual([2])
  })

  it('should not add duplicate books', () => {
    usePdfStore.getState().addBook(1)
    usePdfStore.getState().addBook(1)
    expect(usePdfStore.getState().books).toEqual([1])
  })

  it('should set all books', () => {
    usePdfStore.getState().setAllBooks([1, 2, 3])
    expect(usePdfStore.getState().books).toEqual([1, 2, 3])
  })

  it('should reset paragraph state', () => {
    usePdfStore.setState({
      isDualPage: true,
      pageCount: 100,
      highlightedParagraphIndex: 'test',
      isHighlighting: true,
      isRenderedPageState: { 1: true, 2: true }
    })
    usePdfStore.getState().resetParagraphState()
    expect(usePdfStore.getState().isDualPage).toBe(false)
    expect(usePdfStore.getState().pageCount).toBe(0)
    expect(usePdfStore.getState().highlightedParagraphIndex).toBe('')
    expect(usePdfStore.getState().isHighlighting).toBe(false)
    expect(usePdfStore.getState().isRenderedPageState).toEqual({})
  })

  // --- #142 footer-mask plumbing -------------------------------------------

  it('getFooterMaskForPage returns undefined when pdfFooterDetection is off', () => {
    const mask = new Map<number, Set<number>>([[5, new Set([2, 3])]])
    usePdfStore.getState().setFooterMask(1, mask)

    // Sanity: with the pref ON, the mask is returned.
    usePrefsStore.setState({ pdfFooterDetection: true })
    expect(usePdfStore.getState().getFooterMaskForPage(1, 5)).toEqual(new Set([2, 3]))

    // With the pref OFF, the store treats the mask as if it weren't there.
    usePrefsStore.setState({ pdfFooterDetection: false })
    expect(usePdfStore.getState().getFooterMaskForPage(1, 5)).toBeUndefined()

    // Underlying map is untouched — the gate is purely on the read path.
    expect(usePdfStore.getState().footerMaskByBookId[1]).toBe(mask)
  })

  it('removeBook drops the footer mask entry for that book', () => {
    const mask = new Map<number, Set<number>>([[5, new Set([2, 3])]])
    usePdfStore.getState().addBook(1)
    usePdfStore.getState().setFooterMask(1, mask)
    expect(Object.prototype.hasOwnProperty.call(usePdfStore.getState().footerMaskByBookId, 1)).toBe(
      true
    )

    usePdfStore.getState().removeBook(1)

    expect(Object.prototype.hasOwnProperty.call(usePdfStore.getState().footerMaskByBookId, 1)).toBe(
      false
    )
    expect(usePdfStore.getState().footerMaskByBookId[1]).toBeUndefined()
  })
})
