import { useEffect, useState, type RefObject } from 'react'

import { usePdfStore } from '@/stores/pdfStore'

export function usePdfNavigation(containerRef?: RefObject<HTMLElement | null>) {
  const numPages = usePdfStore((s) => s.pageCount)
  const setNumPages = usePdfStore((s) => s.setPageCount)

  // Measure the scroll container directly so sizing accounts for the vertical
  // scrollbar (overflow-y-scroll reserves ~17px on Windows) and any horizontal
  // padding inside it. clientWidth excludes the scrollbar by definition;
  // window.innerWidth does not, which is what produced a phantom horizontal
  // scrollbar on Windows.
  const [containerSize, setContainerSize] = useState({
    width: typeof window !== 'undefined' ? window.innerWidth : 1024,
    height: typeof window !== 'undefined' ? window.innerHeight : 768
  })
  const [isFullscreen, setIsFullscreen] = useState(false)

  // Determine if we should show dual-page view
  const isDualPage = usePdfStore((s) => s.isDualPage)

  // 16px = the px-2 padding on the inner flex wrapper that hosts pages.
  const HORIZONTAL_PADDING = 16
  const pdfHeight = containerSize.height - 10
  const pdfWidth = containerSize.width - HORIZONTAL_PADDING
  // Calculate page dimensions: in dual-page mode, each page gets half the width
  const dualPageWidth = isDualPage ? pdfWidth / 2 - 6 : pdfWidth // 6px for gap between pages

  // Track container resize and fullscreen changes. ResizeObserver fires once
  // synchronously on observe(), so the first paint after mount has correct
  // dimensions even on the initial render.
  useEffect(() => {
    const el = containerRef?.current
    const update = (): void => {
      if (el) {
        setContainerSize({ width: el.clientWidth, height: el.clientHeight })
      } else {
        setContainerSize({ width: window.innerWidth, height: window.innerHeight })
      }
    }

    const checkFullscreen = (): void => {
      setIsFullscreen(document.fullscreenElement !== null)
    }

    let ro: ResizeObserver | null = null
    if (el && typeof ResizeObserver !== 'undefined') {
      ro = new ResizeObserver(update)
      ro.observe(el)
    } else {
      window.addEventListener('resize', update)
    }

    document.addEventListener('fullscreenchange', checkFullscreen)
    update()
    checkFullscreen()

    return () => {
      if (ro) ro.disconnect()
      else window.removeEventListener('resize', update)
      document.removeEventListener('fullscreenchange', checkFullscreen)
    }
  }, [containerRef])

  const previousPage = usePdfStore((s) => s.previousPage)
  const nextPage = usePdfStore((s) => s.nextPage)

  return {
    previousPage,
    nextPage,
    setNumPages,
    numPages,
    isDualPage,
    pdfHeight,
    pdfWidth,
    dualPageWidth,
    isFullscreen
  }
}
