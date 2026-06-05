import { pdfRectToScreen, screenPointToPdf } from '@/components/pdf/coord-transform'

describe('pdfRectToScreen', () => {
  const page = { widthPts: 612, heightPts: 792 }
  const viewport = { widthPx: 612, heightPx: 792, scale: 1 }

  it('maps origin bottom-left to origin top-left with y-flip', () => {
    // PDF rect at top-left of page: x=0, y=792-12=780, w=100, h=12.
    const out = pdfRectToScreen(
      { x: 0, y: 780, w: 100, h: 12 },
      page,
      viewport,
    )
    expect(out).toEqual({ left: 0, top: 0, width: 100, height: 12 })
  })

  it('scales rects by viewport scale', () => {
    const out = pdfRectToScreen(
      { x: 0, y: 780, w: 100, h: 12 },
      page,
      { widthPx: 612, heightPx: 792, scale: 2 },
    )
    expect(out).toEqual({ left: 0, top: 0, width: 200, height: 24 })
  })

  it('handles partial-page viewport widths', () => {
    // PDF is 612 pts; viewport renders 306 px wide (half-scale).
    const out = pdfRectToScreen(
      { x: 306, y: 396, w: 100, h: 100 },
      page,
      { widthPx: 306, heightPx: 396, scale: 1 },
    )
    expect(out.left).toBeCloseTo(153, 1)
    expect(out.top).toBeCloseTo(148, 1)   // (792 - 396 - 100) / 792 * 396
    expect(out.width).toBeCloseTo(50, 1)
    expect(out.height).toBeCloseTo(50, 1)
  })
})

describe('screenPointToPdf', () => {
  const page = { widthPts: 612, heightPts: 792 }
  const viewport = { widthPx: 612, heightPx: 792, scale: 1 }

  it('inverts pdfRectToScreen for a corner point', () => {
    const screenPoint = { x: 0, y: 0 }       // top-left screen
    const pdfPoint = screenPointToPdf(screenPoint, page, viewport)
    expect(pdfPoint).toEqual({ x: 0, y: 792 }) // top-left PDF (y=heightPts)
  })
})
