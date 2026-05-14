import { useRef, useEffect } from 'react'
import { Thumbnail } from 'react-pdf'
import { useThumbnailVirtualizer } from '../hooks/useThumbnailVirtualizer'
import { usePdfStore } from '@/stores/pdfStore'
import { cn } from '@/lib/utils'

const THUMBNAIL_WIDTH = 120
const THUMBNAIL_HEIGHT = 170
const GAP = 8

export function ThumbnailSidebar({
  onClose,
  onNavigate
}: {
  onClose: () => void
  onNavigate: (pageNumber: number) => void
}) {
  const numPages = usePdfStore((s) => s.pageCount)
  const currentPage = usePdfStore((s) => s.pageNumber)
  const pdfProxy = usePdfStore((s) => s.pdfDocumentProxy)
  const containerRef = useRef<HTMLDivElement>(null)

  const thumbVirtualizer = useThumbnailVirtualizer({
    count: numPages,
    getScrollElement: () => containerRef.current,
    estimateSize: () => THUMBNAIL_HEIGHT + GAP,
    overscan: 3
  })

  // Snapshot the latest virtualizer + current page in refs so the
  // mount-only scroll-to effect doesn't have to depend on values that
  // change every render (`thumbVirtualizer` identity churns each render
  // and `currentPage` advances as the user reads — depending on them
  // would re-fire the auto-scroll on every page turn, hijacking the
  // sidebar's manual scroll position).
  const thumbVirtualizerRef = useRef(thumbVirtualizer)
  const currentPageRef = useRef(currentPage)
  useEffect(() => {
    thumbVirtualizerRef.current = thumbVirtualizer
    currentPageRef.current = currentPage
  })

  useEffect(() => {
    const page = currentPageRef.current
    if (page > 0) {
      thumbVirtualizerRef.current.scrollToIndex(page - 1, { align: 'center' })
    }
  }, [])

  const handleClick = (pageNum: number) => {
    onNavigate(pageNum)
    onClose()
  }

  return (
    <div ref={containerRef} className="overflow-y-auto h-full p-2">
      <div
        style={{
          height: thumbVirtualizer.getTotalSize(),
          position: 'relative',
          width: '100%'
        }}
      >
        {thumbVirtualizer.getVirtualItems().map((item) => {
          const pageNum = item.index + 1
          return (
            <div
              key={item.key}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                width: '100%',
                height: `${item.size}px`,
                transform: `translateY(${item.start}px)`
              }}
              className="flex flex-col items-center"
            >
              <Thumbnail
                pageNumber={pageNum}
                width={THUMBNAIL_WIDTH}
                pdf={pdfProxy ?? undefined}
                onItemClick={() => handleClick(pageNum)}
                className={cn(
                  'cursor-pointer border-2 rounded transition-colors',
                  currentPage === pageNum
                    ? 'border-blue-500 shadow-md'
                    : 'border-transparent hover:border-gray-300'
                )}
              />
              <span className="text-xs text-gray-500 mt-1">{pageNum}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}
