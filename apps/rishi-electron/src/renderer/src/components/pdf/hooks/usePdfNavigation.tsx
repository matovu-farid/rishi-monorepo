import { useEffect, useState } from 'react'

import { usePdfStore } from '@/stores/pdfStore'

export function usePdfNavigation() {
  const numPages = usePdfStore((s) => s.pageCount)
  const setNumPages = usePdfStore((s) => s.setPageCount)

  const [windowSize, setWindowSize] = useState({
    width: typeof window !== 'undefined' ? window.innerWidth : 1024,
    height: typeof window !== 'undefined' ? window.innerHeight : 768
  })
  const [isFullscreen, setIsFullscreen] = useState(false)

  // Determine if we should show dual-page view
  const isDualPage = usePdfStore((s) => s.isDualPage)

  const pdfHeight = windowSize.height - 10 // 60px top + 60px bottom
  const pdfWidth = windowSize.width - 10
  // Calculate page dimensions: in dual-page mode, each page gets half the width
  const dualPageWidth = isDualPage ? (windowSize.width - 10) / 2 - 6 : pdfWidth // 6px for gap between pages

  // Track window resize and fullscreen changes
  useEffect(() => {
    const handleResize = () => {
      setWindowSize({
        width: window.innerWidth,
        height: window.innerHeight
      })
    }

    const checkFullscreen = () => {
      // Use browser fullscreen API (works in Electron)
      setIsFullscreen(document.fullscreenElement !== null)
    }

    window.addEventListener('resize', handleResize)

    const handleResizeAndFullscreen = () => {
      handleResize()
      checkFullscreen()
    }

    window.addEventListener('resize', handleResizeAndFullscreen)
    document.addEventListener('fullscreenchange', checkFullscreen)

    // Initial check
    checkFullscreen()

    return () => {
      window.removeEventListener('resize', handleResizeAndFullscreen)
      document.removeEventListener('fullscreenchange', checkFullscreen)
    }
  }, [])

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
