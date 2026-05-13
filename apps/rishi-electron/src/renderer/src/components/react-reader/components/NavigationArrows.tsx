import { ChevronLeft, ChevronRight } from 'lucide-react'

// Props for NavigationArrows component
export type NavigationArrowsProps = {
  onPrev: () => void
  onNext: () => void
  /** Hide the previous-page button (e.g. when on the first page). */
  hidePrev?: boolean
  /** Hide the next-page button (e.g. when on the last page). */
  hideNext?: boolean
}

/**
 * NavigationArrows Component
 * Renders semi-transparent left/right arrow buttons overlaid on the reader edges.
 * Becomes more visible on hover.
 */
export const NavigationArrows = ({
  onPrev,
  onNext,
  hidePrev = false,
  hideNext = false
}: NavigationArrowsProps) => {
  const buttonClass =
    'absolute top-1/2 -translate-y-1/2 z-10 flex items-center justify-center ' +
    'w-12 h-24 text-gray-300 hover:text-gray-600 ' +
    'opacity-40 hover:opacity-100 transition-opacity duration-200 ' +
    'cursor-pointer select-none bg-transparent border-none outline-none'

  return (
    <>
      {/* Previous page arrow button -- hidden on cover page */}
      {!hidePrev && (
        <button
          className={`${buttonClass} left-0`}
          onClick={onPrev}
          onPointerDown={(e) => e.stopPropagation()}
          aria-label="Previous page"
        >
          <ChevronLeft size={40} />
        </button>
      )}

      {/* Next page arrow button -- hidden on last page */}
      {!hideNext && (
        <button
          className={`${buttonClass} right-0`}
          onClick={onNext}
          onPointerDown={(e) => e.stopPropagation()}
          aria-label="Next page"
        >
          <ChevronRight size={40} />
        </button>
      )}
    </>
  )
}
