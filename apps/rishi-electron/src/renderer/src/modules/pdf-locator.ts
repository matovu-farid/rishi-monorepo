import type { PdfLocator } from './highlight-storage'

// Structural subset of pdfjs's PageViewport — anything real from pdfjs satisfies this.
export interface ViewportLike {
  width: number
  height: number
  scale: number
  convertToViewportPoint(pdfX: number, pdfY: number): [number, number]
  convertToPdfPoint(viewportX: number, viewportY: number): [number, number]
}

function findPageAncestor(node: Node | null): HTMLElement | null {
  let cur: Node | null = node
  while (cur) {
    if (cur instanceof HTMLElement && cur.classList.contains('react-pdf__Page')) return cur
    cur = cur.parentNode
  }
  return null
}

export function selectionToPdfLocator(
  range: Range,
  pageEl: HTMLElement,
  viewport: ViewportLike,
  pageNumber: number
): PdfLocator | null {
  if (range.collapsed) return null
  const startPage = findPageAncestor(range.startContainer)
  const endPage = findPageAncestor(range.endContainer)
  if (!startPage || !endPage || startPage !== endPage) return null

  const pageRect = pageEl.getBoundingClientRect()
  const clientRects = Array.from(range.getClientRects())
  if (clientRects.length === 0) return null

  const rects: PdfLocator['rects'] = []
  for (const r of clientRects) {
    const vxLeft = r.left - pageRect.left
    const vyTop = r.top - pageRect.top
    const vxRight = vxLeft + r.width
    const vyBottom = vyTop + r.height

    const [pdfXLeft, pdfYBottom] = viewport.convertToPdfPoint(vxLeft, vyBottom)
    const [pdfXRight, pdfYTop] = viewport.convertToPdfPoint(vxRight, vyTop)
    const w = pdfXRight - pdfXLeft
    const h = pdfYTop - pdfYBottom
    if (w <= 0 || h <= 0) continue
    rects.push({ x: pdfXLeft, y: pdfYBottom, w, h })
  }
  if (rects.length === 0) return null
  return { page: pageNumber, rects }
}

export function pdfLocatorToScreenRects(
  locator: PdfLocator,
  _pageEl: HTMLElement,
  viewport: ViewportLike
): Array<{ left: number; top: number; width: number; height: number }> {
  // _pageEl is unused — screen rects are returned page-relative; callers position them in CSS via the page wrapper's positioning context.
  return locator.rects.map((r) => {
    const [vxLeft, vyBottom] = viewport.convertToViewportPoint(r.x, r.y)
    const [vxRight, vyTop] = viewport.convertToViewportPoint(r.x + r.w, r.y + r.h)
    return {
      left: vxLeft,
      top: vyTop,
      width: vxRight - vxLeft,
      height: vyBottom - vyTop
    }
  })
}
