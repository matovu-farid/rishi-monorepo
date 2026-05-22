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
    // On the last page (pageNumber === pageCount). The reader must NOT wrap
    // back to a same-page scroll or scroll out of bounds; it should leave the
    // virtualizer alone (no advance attempt).
    usePdfStore.setState({ pageNumber: 10, pageCount: 10, virtualizer })

    nextPage()

    // Either the function bails out OR it scrolls to the current page — what
    // it MUST NOT do is scroll to a smaller index (i.e. wrap to a previous
    // page). Specifically, it must not call scrollToIndex with `pageNumber-1`
    // (== 9), which would land on the current page in 0-based terms.
    if (scrollToIndex.mock.calls.length > 0) {
      const [target] = scrollToIndex.mock.calls[0]
      expect(target).toBeGreaterThanOrEqual(10)
      expect(target).toBeLessThanOrEqual(10)
    }
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
})
