/**
 * Compute outer-viewport coordinates for an inline-highlight popover from
 * an epubjs annotation click event.
 *
 * The event target is an SVG node inside the iframe document, so:
 *   - `instanceof Element` against this window's Element returns false
 *     (different realm) and must not be used as a gate.
 *   - `e.clientX/Y` are iframe-local; we add the iframe's bounding rect
 *     to convert to the outer viewport.
 *
 * Falls back to mid-viewport so the popover is always at least visible,
 * even when the event or iframe lookup fails.
 */
export function computeHighlightClickPosition(
  e: MouseEvent | undefined,
  fallbackIframe?: HTMLElement | null,
  viewport: { innerWidth: number; innerHeight: number } = window
): { x: number; y: number } {
  const target = e?.target as Element | null | undefined
  const eventIframe =
    (target?.ownerDocument?.defaultView?.frameElement as HTMLElement | null) ?? null
  const iframeEl = eventIframe ?? fallbackIframe ?? null
  const rect = iframeEl?.getBoundingClientRect?.()
  if (rect && e && typeof e.clientX === 'number' && typeof e.clientY === 'number') {
    return { x: rect.left + e.clientX, y: rect.top + e.clientY }
  }
  return { x: viewport.innerWidth / 2, y: viewport.innerHeight / 2 }
}
