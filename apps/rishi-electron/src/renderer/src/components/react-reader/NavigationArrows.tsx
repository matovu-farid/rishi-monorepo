import { ChevronLeft, ChevronRight } from 'lucide-react'

export interface NavigationArrowsProps {
  onPrev: () => void
  onNext: () => void
  hidePrev?: boolean
  hideNext?: boolean
}

/**
 * NavigationArrows Component
 * Renders semi-transparent left/right arrow buttons overlaid on the reader edges.
 * Becomes more visible on hover.
 *
 * Theme contract:
 *   - Arrow color uses `text-muted-foreground` / `hover:text-foreground` so
 *     contrast tracks the active app theme (light/dark).
 *   - `motion-reduce:transition-none` honors `prefers-reduced-motion`.
 *   - `focus-visible:ring-2 focus-visible:ring-ring` adds a visible focus
 *     indicator (WCAG 2.4.7).
 */
export function NavigationArrows({
  onPrev,
  onNext,
  hidePrev = false,
  hideNext = false
}: NavigationArrowsProps) {
  const buttonClass =
    'absolute top-1/2 -translate-y-1/2 z-10 flex items-center justify-center ' +
    'w-12 h-24 text-muted-foreground hover:text-foreground ' +
    'opacity-40 hover:opacity-100 transition-opacity duration-200 motion-reduce:transition-none ' +
    'cursor-pointer select-none bg-transparent border-none ' +
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:rounded-md'

  return (
    <>
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
