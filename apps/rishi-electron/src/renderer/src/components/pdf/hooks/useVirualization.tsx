import React, { useEffect, useRef, useCallback } from 'react'

import { useVirtualizer } from '@tanstack/react-virtual'

// Import required CSS for text and annotation layers
import 'react-pdf/dist/Page/AnnotationLayer.css'
import 'react-pdf/dist/Page/TextLayer.css'

import { elementScroll } from '@tanstack/react-virtual'
import type { VirtualizerOptions } from '@tanstack/react-virtual'
import { usePdfStore } from '@/stores/pdfStore'
import { parsePdfLocation } from '@/lib/pdfLocation'
import { PAGE_HEIGHT, PAGE_GAP } from '../utils/constants'
import type { Book } from '@/lib/api'
function easeInOutQuint(t: number) {
  return t < 0.5 ? 16 * t * t * t * t * t : 1 + 16 * --t * t * t * t * t
}
export function useVirualization(
  scrollContainerRef: React.RefObject<HTMLDivElement | null>,
  book: Book
) {
  const initialPosition = parsePdfLocation(book.location)
  const initialPageIndexRef = useRef(Math.max(0, initialPosition.page - 1))
  const numPages = usePdfStore((s) => s.pageCount)
  const setHasNavigatedToPage = usePdfStore((s) => s.setHasNavigatedToPage)
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
  const scrollToFn: VirtualizerOptions<any, any>['scrollToFn'] = React.useCallback(
    (offset, canSmooth, instance) => {
      // Skip the smooth animation when:
      //   - behavior is 'auto' (instant navigation), or
      //   - the virtualizer is sending an `adjustments` value to compensate
      //     for layout shifts after item re-measurement. Animating only
      //     `offset` while `elementScroll` silently adds `adjustments` to the
      //     final scrollTop produces drifting scroll positions and lands the
      //     user on the wrong page on every reopen.
      if (canSmooth?.behavior === 'auto' || canSmooth?.adjustments) {
        elementScroll(offset, canSmooth, instance)
        return
      }

      const duration = 1000
      const start = scrollContainerRef.current?.scrollTop || 0
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
    []
  )

  const virtualizer = useVirtualizer({
    count: numPages,
    getScrollElement: () => scrollContainerRef.current,
    estimateSize: () => estimatedPageHeight,
    overscan: 8,
    enabled: numPages > 0,
    initialOffset: initialOffsetRef.current,
    scrollToFn,
    gap: PAGE_GAP
  })
  setVirtualizer(virtualizer)
  const handlePageRendered = useCallback(
    (_index: number) => {
      setHasNavigatedToPage(true)
    },
    [virtualizer]
  )

  useEffect(() => {
    if (hasRequestedInitialScroll.current) return
    if (numPages === 0) return
    if (!scrollContainerRef.current) return

    hasRequestedInitialScroll.current = true
  }, [numPages, virtualizer])

  const virtualItems = virtualizer.getVirtualItems()
  return { virtualizer, virtualItems, pageRefs, handlePageRendered }
}
