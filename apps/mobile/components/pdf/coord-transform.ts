/**
 * Pure transforms between PDF user-space (origin bottom-left, points)
 * and screen space (origin top-left, pixels). All highlight rendering,
 * gesture hit-testing, and selection math should go through these
 * functions — never sprinkle ad-hoc y-flips into components.
 */

export interface PdfRect { x: number; y: number; w: number; h: number }
export interface ScreenRect { left: number; top: number; width: number; height: number }
export interface PageSize { widthPts: number; heightPts: number }
export interface Viewport { widthPx: number; heightPx: number; scale: number }

export function pdfRectToScreen(
  rect: PdfRect,
  page: PageSize,
  viewport: Viewport,
): ScreenRect {
  const sx = (viewport.widthPx / page.widthPts) * viewport.scale
  const sy = (viewport.heightPx / page.heightPts) * viewport.scale
  return {
    left:  rect.x * sx,
    top:   (page.heightPts - rect.y - rect.h) * sy,
    width: rect.w * sx,
    height: rect.h * sy,
  }
}

export function screenPointToPdf(
  point: { x: number; y: number },
  page: PageSize,
  viewport: Viewport,
): { x: number; y: number } {
  const sx = (viewport.widthPx / page.widthPts) * viewport.scale
  const sy = (viewport.heightPx / page.heightPts) * viewport.scale
  return {
    x: point.x / sx,
    y: page.heightPts - point.y / sy,
  }
}
