import { useVirtualizer } from '@tanstack/react-virtual'

/**
 * Thin wrapper around `useVirtualizer` for the thumbnail sidebar.
 *
 * `@tanstack/react-virtual` returns un-memoizable function references, so the
 * React Compiler bails out of any function that calls it. Isolating the call
 * here (with the `'use no memo'` directive) keeps the opt-out scoped to a
 * single tiny hook so the parent `ThumbnailSidebar` component stays
 * compilable.
 */
export function useThumbnailVirtualizer(options: {
  count: number
  getScrollElement: () => HTMLElement | null
  estimateSize: () => number
  overscan?: number
}) {
  'use no memo'
  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual returns un-memoizable refs; opt-out is intentional and scoped to this wrapper
  return useVirtualizer({
    count: options.count,
    getScrollElement: options.getScrollElement,
    estimateSize: options.estimateSize,
    overscan: options.overscan
  })
}
