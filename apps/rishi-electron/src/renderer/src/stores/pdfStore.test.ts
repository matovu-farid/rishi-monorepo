import { describe, it, expect, beforeEach } from 'vitest'
import { usePdfStore, BookNavigationState } from './pdfStore'

describe('pdfStore', () => {
  beforeEach(() => {
    // Full replace with the store's initial state so new PdfState fields
    // cannot silently leak across tests.
    usePdfStore.setState(usePdfStore.getInitialState(), true)
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
})
