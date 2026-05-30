import React, { useEffect, useRef, useCallback } from 'react'

import { useVirtualizer } from '@tanstack/react-virtual'

// Import required CSS for text and annotation layers
import 'react-pdf/dist/Page/AnnotationLayer.css'
import 'react-pdf/dist/Page/TextLayer.css'

import { elementScroll } from '@tanstack/react-virtual'
import type { VirtualizerOptions } from '@tanstack/react-virtual'
import { usePdfStore } from '@/stores/pdfStore'
import { parsePdfLocation } from '@/lib/pdfLocation'
import { PAGE_HEIGHT, PAGE_GAP, HORIZONTAL_PADDING } from '../utils/constants'
import type { Book } from '@/lib/api'
function easeInOutQuint(t: number) {
  return t < 0.5 ? 16 * t * t * t * t * t : 1 + 16 * --t * t * t * t * t
}
export function useVirualization(
  scrollContainerRef: React.RefObject<HTMLDivElement | null>,
  book: Book
) {
  'use no memo'
  const initialPosition = parsePdfLocation(book.location)
  const initialPageIndexRef = useRef(Math.max(0, initialPosition.page - 1))
  const numPages = usePdfStore((s) => s.pageCount)
  const setHasNavigatedToPage = usePdfStore((s) => s.setHasNavigatedToPage)
  const getPageDimension = usePdfStore((s) => s.getPageDimension)
  // Subscribe to the dims slice for THIS book so this hook re-renders when
  // setPageDimensions populates measurements. Selecting only the function
  // reference (getPageDimension) is stable and would never trigger a re-run.
  const dimsForBook = usePdfStore((s) => s.pageDimensionsByBookId[book.id])
  // Dual-page mode renders each page at half-container-width with a height-
  // driven scale; the width-driven estimate below would produce ~2x the
  // correct height. Fall back to estimatedPageHeight in dual-page mode —
  // proper dual-page math is out of scope for this iteration.
  const isDualPage = usePdfStore((s) => s.isDualPage)
  const estimatedPageHeight = PAGE_HEIGHT
  const scrollingRef = useRef<number | null>(null)
  // initialOffset uses ESTIMATED page heights — the virtualizer hasn't
  // measured anything yet. Don't add the saved sub-page offset here: the
  // estimated page-N start usually differs from the measured page-N start
  // by hundreds of pixels, so adding the (measured) sub-page offset to the
  // (estimated) page start lands the user wildly off. usePdfReader applies
  // the sub-page offset after the seek-landed poll has snapped to the
  // correct measured page start.
  const initialOffsetRef = useRef(initialPageIndexRef.current * (estimatedPageHeight + PAGE_GAP))
  const setVirtualizer = usePdfStore((s) => s.setVirtualizer)
  const pageRefs = useRef(new Map<number, HTMLElement>())
  const hasRequestedInitialScroll = useRef(false)
  const scrollToFn: VirtualizerOptions<HTMLDivElement, Element>['scrollToFn'] = React.useCallback(
    (offset, canSmooth, instance) => {
      // Skip the smooth animation when:
      //   - behavior is 'auto' (instant navigation), or
      //   - the virtualizer is sending an `adjustments` value to compensate
      //     for layout shifts after item re-measurement. Animating only
      //     `offset` while `elementScroll` silently adds `adjustments` to the
      //     final scrollTop produces drifting scroll positions and lands the
      //     user on the wrong page on every reopen.
      if (canSmooth.behavior === 'auto' || canSmooth.adjustments) {
        elementScroll(offset, canSmooth, instance)
        return
      }

      const duration = 1000
      const start = scrollContainerRef.current?.scrollTop ?? 0
      const startTime = (scrollingRef.current = Date.now())

      const run = () => {
        if (scrollingRef.current !== startTime) return
        const now = Date.now()
        const elapsed = now - startTime
        const progress = easeInOutQuint(Math.min(elapsed / duration, 1))
        const interpolated = start + (offset - start) * progress

        if (elapsed < duration) {
          elementScroll(interpolated, canSmooth, instance)
          requestAnimationFrame(run)
        } else {
          elementScroll(interpolated, canSmooth, instance)
        }
      }

      requestAnimationFrame(run)
    },
    [scrollContainerRef]
  )

  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual returns un-memoizable refs; hook opts out via 'use no memo' above
  const virtualizer = useVirtualizer({
    count: numPages,
    getScrollElement: () => scrollContainerRef.current,
    estimateSize: (index: number) => {
      // Dual-page mode uses a height-driven, half-width per-page scale; this
      // width-driven estimate doesn't apply. Defer to the constant estimate
      // and let post-measurement adjustments take over.
      if (isDualPage) return estimatedPageHeight
      const dim = getPageDimension(book.id, index)
      if (!dim) return estimatedPageHeight
      const containerWidth = scrollContainerRef.current?.clientWidth
      if (!containerWidth) return estimatedPageHeight
      // Mirror the per-page scale derivation used at render time
      // (PdfView line ~154): scale = renderedWidth / page.view[2].
      // Subtract HORIZONTAL_PADDING (matches usePdfNavigation.pdfWidth) so the
      // estimate matches the actual rendered width — otherwise we over-estimate
      // by containerWidth / (containerWidth - 16) and trigger post-measurement
      // adjustments on every page.
      const renderedWidth = containerWidth - HORIZONTAL_PADDING
      if (renderedWidth <= 0 || dim.baseWidth <= 0) return estimatedPageHeight
      const scale = renderedWidth / dim.baseWidth
      return dim.baseHeight * scale
    },
    overscan: 8,
    enabled: numPages > 0,
    initialOffset: initialOffsetRef.current,
    scrollToFn,
    gap: PAGE_GAP
  })
  setVirtualizer(virtualizer)

  // TanStack Virtual caches estimateSize per index. When setPageDimensions
  // populates dims after the initial render, the cached estimates remain
  // stale. Calling virtualizer.measure() invalidates the per-index cache
  // so the next render re-runs estimateSize with the real per-page
  // dimensions.
  //
  // The invalidation MUST fire at most once per book. Each call to
  // measure() causes TanStack to recompute layout, which shifts scroll
  // position to compensate for newly-corrected estimates. If the user is
  // scrolling near a page boundary at that moment, the shift is felt as
  // a "snap." Repeated invalidations (e.g., if setPageDimensions ever
  // gets called twice for the same book, or if the virtualizer instance
  // changes across renders) compound the problem. Guarding with a ref
  // keyed on book.id caps it at one invalidation per book — the
  // unavoidable initial transition from fallback to real dims.
  const measuredOnceForBookRef = useRef<number | null>(null)
  useEffect(() => {
    if (!dimsForBook) return
    if (measuredOnceForBookRef.current === book.id) return
    measuredOnceForBookRef.current = book.id
    virtualizer.measure()
  }, [dimsForBook, virtualizer, book.id])

  const handlePageRendered = useCallback(() => {
    setHasNavigatedToPage(true)
  }, [setHasNavigatedToPage])

  useEffect(() => {
    if (hasRequestedInitialScroll.current) return
    if (numPages === 0) return
    if (!scrollContainerRef.current) return

    hasRequestedInitialScroll.current = true
  }, [numPages, virtualizer, scrollContainerRef])

  const virtualItems = virtualizer.getVirtualItems()
  return { virtualizer, virtualItems, pageRefs, handlePageRendered }
}
