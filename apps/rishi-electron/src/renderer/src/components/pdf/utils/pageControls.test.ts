import { describe, it, expect, beforeEach, vi } from 'vitest'
import type { Mock } from 'vitest'
import { nextPage, previousPage } from './pageControls'
import { usePdfStore, type PdfVirtualizer } from '@/stores/pdfStore'

/**
 * Builds a stub virtualizer with a stubbed scrollToIndex method so we can
 * assert the index `pageControls.nextPage()` chooses without spinning up a
 * full tanstack/virtual instance.
 */
function makeStubVirtualizer(): { virtualizer: PdfVirtualizer; scrollToIndex: Mock } {
  const scrollToIndex = vi.fn()
  // The rest of the Virtualizer API is intentionally unimplemented — tests
  // only exercise scrollToIndex. Cast through unknown so we don't have to
  // synthesize every internal field.
  const virtualizer = { scrollToIndex } as unknown as PdfVirtualizer
  return { virtualizer, scrollToIndex }
}

describe('pageControls.nextPage — page-boundary advance (issue #30)', () => {
  beforeEach(() => {
    // Full reset so each test sees the canonical initial pdfStore.
    usePdfStore.setState(usePdfStore.getInitialState(), true)
  })

  it('advances from page N to page N+1 (scrolls to virtual index N) — mid-document', () => {
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    // pageNumber is 1-based. The virtualizer is indexed 0-based, so virtual
    // index `N` corresponds to 1-based page N+1.
    usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer })

    nextPage()

    expect(scrollToIndex).toHaveBeenCalledTimes(1)
    // After advancing from page 5 we want to land on page 6, which is virtual
    // index 5 (= pageNumber).
    expect(scrollToIndex).toHaveBeenCalledWith(5, expect.objectContaining({ align: 'start' }))
  })

  it('advances from page 1 (the first page) to page 2 (virtual index 1)', () => {
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    usePdfStore.setState({ pageNumber: 1, pageCount: 10, virtualizer })

    nextPage()

    expect(scrollToIndex).toHaveBeenCalledWith(1, expect.objectContaining({ align: 'start' }))
  })

  it('does NOT scroll past the last page of the document (issue #30 edge case)', () => {
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    // On the last page (pageNumber === pageCount). The reader must NOT call
    // scrollToIndex at all — there is no virtual index >= pageCount to scroll
    // to (the virtualizer is 0..pageCount-1), and asking it to scroll past the
    // end leaves the suppression flag stuck `true` for the rest of the session
    // (PR #31 review: pullrequestreview-4348558706). "Past last page"
    // semantics: nextPage() is a no-op when already on the final page.
    usePdfStore.setState({ pageNumber: 10, pageCount: 10, virtualizer })

    nextPage()

    expect(scrollToIndex).not.toHaveBeenCalled()
  })

  it('does NOT scroll before the first page of the document (symmetry with last-page guard)', () => {
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    // On the first page. previousPage() must be a no-op so it can't set the
    // flag and then ask the virtualizer to scroll to virtual index -1, which
    // would also leave the suppression flag stuck `true`.
    usePdfStore.setState({ pageNumber: 1, pageCount: 10, virtualizer })

    previousPage()

    expect(scrollToIndex).not.toHaveBeenCalled()
  })

  it('does NOT leave isLookingForNextParagraph stuck true when nextPage is called on the last page (PR #31 review)', () => {
    // Bug surface (review pullrequestreview-4348558706): when the player
    // reaches the last paragraph of the last page it still asks the view
    // actor to advance (pdfViewActor calls nextPage on NAVIGATE_NEXT).
    // pageControls.nextPage had no bounds check, so it set the flag `true`,
    // called scrollToIndex with an out-of-bounds index, no page render
    // happened, `currentDiffers` never flipped, and the flag stayed `true`
    // for the rest of the session — silently denying auto-scroll for every
    // subsequent highlight.
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    usePdfStore.setState({
      pageNumber: 10,
      pageCount: 10,
      virtualizer,
      isLookingForNextParagraph: false
    })

    nextPage()

    // No out-of-bounds scroll attempted...
    expect(scrollToIndex).not.toHaveBeenCalled()
    // ...and the suppression flag must NOT have been flipped, because nothing
    // is ever going to clear it (no new page will render).
    expect(usePdfStore.getState().isLookingForNextParagraph).toBe(false)
  })

  it('does NOT leave isLookingForNextParagraph stuck true when previousPage is called on the first page', () => {
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    usePdfStore.setState({
      pageNumber: 1,
      pageCount: 10,
      virtualizer,
      isLookingForNextParagraph: false
    })

    previousPage()

    expect(scrollToIndex).not.toHaveBeenCalled()
    expect(usePdfStore.getState().isLookingForNextParagraph).toBe(false)
  })

  it('previousPage: regression sanity — page 5 -> virtual index 3 (page 4)', () => {
    const { virtualizer, scrollToIndex } = makeStubVirtualizer()
    usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer })

    previousPage()

    expect(scrollToIndex).toHaveBeenCalledWith(3, expect.objectContaining({ align: 'end' }))
  })

  it('keeps isLookingForNextParagraph TRUE across the scroll so useScrolling does not snap back', () => {
    // Bug surface: pageControls.nextPage previously set the flag to true
    // and then synchronously cleared it on the same tick. useScrolling reads
    // the flag inside a 100 ms timeout, so it always observed `false` and
    // happily auto-scrolled the highlighted (old-page) <mark> back into view —
    // producing the "returns to first paragraph of page N" behaviour reported
    // in issue #30. The flag MUST remain truthy after nextPage() returns so
    // useScrolling's next tick observes it.
    const { virtualizer } = makeStubVirtualizer()
    usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer })

    nextPage()

    // After nextPage() returns synchronously, the suppression flag must still
    // be true. (A later signal — paragraphs updated for the new page —
    // resets it; that's the responsibility of the publishing pipeline, not
    // the scroller.)
    expect(usePdfStore.getState().isLookingForNextParagraph).toBe(true)
  })

  it('previousPage also keeps the suppression flag true after the scroll', () => {
    const { virtualizer } = makeStubVirtualizer()
    usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer })

    previousPage()

    expect(usePdfStore.getState().isLookingForNextParagraph).toBe(true)
  })

  // The boolean return is what pdfViewActor uses to distinguish "navigation
  // initiated, wait for snapshot" from "at boundary, give up immediately."
  // Without this signal the actor would have to wait for the 10 s nav timeout
  // before transitioning to `stopped` at the end of the document.
  describe('boolean return (pdfViewActor contract)', () => {
    it('nextPage returns true mid-document (navigation initiated)', () => {
      const { virtualizer } = makeStubVirtualizer()
      usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer })
      expect(nextPage()).toBe(true)
    })

    it('nextPage returns false on the last page (no scroll, no nav)', () => {
      const { virtualizer } = makeStubVirtualizer()
      usePdfStore.setState({ pageNumber: 10, pageCount: 10, virtualizer })
      expect(nextPage()).toBe(false)
    })

    it('nextPage returns false when the virtualizer is not yet mounted', () => {
      usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer: null })
      expect(nextPage()).toBe(false)
    })

    it('previousPage returns true mid-document', () => {
      const { virtualizer } = makeStubVirtualizer()
      usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer })
      expect(previousPage()).toBe(true)
    })

    it('previousPage returns false on the first page', () => {
      const { virtualizer } = makeStubVirtualizer()
      usePdfStore.setState({ pageNumber: 1, pageCount: 10, virtualizer })
      expect(previousPage()).toBe(false)
    })

    it('previousPage returns false when the virtualizer is not yet mounted', () => {
      usePdfStore.setState({ pageNumber: 5, pageCount: 10, virtualizer: null })
      expect(previousPage()).toBe(false)
    })
  })
})
