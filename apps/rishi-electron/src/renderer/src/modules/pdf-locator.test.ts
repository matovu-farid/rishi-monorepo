import { describe, it, expect } from 'vitest'
import { selectionToPdfLocator, pdfLocatorToScreenRects } from './pdf-locator'

// Minimal fake of pdfjs PageViewport. The real one comes from pdf.getPage(n).getViewport({scale}).
function makeViewport(opts: { width: number; height: number; scale: number }) {
  return {
    width: opts.width,
    height: opts.height,
    scale: opts.scale,
    // For an unrotated page: viewportX = pdfX * scale; viewportY = (pageHeightPdf - pdfY) * scale
    convertToViewportPoint(pdfX: number, pdfY: number): [number, number] {
      const pageHeightPdf = opts.height / opts.scale
      return [pdfX * opts.scale, (pageHeightPdf - pdfY) * opts.scale]
    },
    convertToPdfPoint(vx: number, vy: number): [number, number] {
      const pageHeightPdf = opts.height / opts.scale
      return [vx / opts.scale, pageHeightPdf - vy / opts.scale]
    }
  } as const
}

function makePageEl(rect: { left: number; top: number; width: number; height: number }): HTMLElement {
  const div = document.createElement('div')
  Object.defineProperty(div, 'getBoundingClientRect', {
    value: () => ({
      left: rect.left, top: rect.top,
      right: rect.left + rect.width, bottom: rect.top + rect.height,
      width: rect.width, height: rect.height, x: rect.left, y: rect.top,
      toJSON() { return this }
    })
  })
  return div
}

describe('pdf-locator', () => {
  describe('selectionToPdfLocator', () => {
    it('returns null when range is collapsed', () => {
      const range = document.createRange()
      const pageEl = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      expect(selectionToPdfLocator(range, pageEl, viewport as never, 1)).toBeNull()
    })

    it('returns null if start and end resolve to different page elements', () => {
      const pageA = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      const pageB = makePageEl({ left: 0, top: 700, width: 400, height: 600 })
      pageA.className = 'react-pdf__Page'
      pageB.className = 'react-pdf__Page'
      const t1 = document.createTextNode('hello')
      const t2 = document.createTextNode('world')
      pageA.appendChild(t1); pageB.appendChild(t2)
      const range = document.createRange()
      range.setStart(t1, 0); range.setEnd(t2, 5)
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      expect(selectionToPdfLocator(range, pageA, viewport as never, 1)).toBeNull()
    })

    it('converts a single client rect into PDF coords with bottom-left origin', () => {
      const pageEl = makePageEl({ left: 50, top: 100, width: 400, height: 600 })
      pageEl.className = 'react-pdf__Page'
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      const range = document.createRange()
      const text = document.createTextNode('xyz')
      pageEl.appendChild(text)
      range.setStart(text, 0); range.setEnd(text, 3)
      Object.defineProperty(range, 'getClientRects', {
        value: () => [{ left: 60, top: 120, width: 100, height: 15, right: 160, bottom: 135 }]
      })

      const result = selectionToPdfLocator(range, pageEl, viewport as never, 7)
      expect(result).toEqual({
        page: 7,
        rects: [
          // viewport top-left of rect is (10, 20) relative to page.
          // bottom-left in PDF coords: x=10, y=600-35=565. w=100, h=15.
          { x: 10, y: 565, w: 100, h: 15 }
        ]
      })
    })

    it('produces stable locators across zoom (round-trip @ scale=2)', () => {
      const pageEl1 = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      pageEl1.className = 'react-pdf__Page'
      const vp1 = makeViewport({ width: 400, height: 600, scale: 1 })
      const range = document.createRange()
      const t = document.createTextNode('abcdef')
      pageEl1.appendChild(t)
      range.setStart(t, 0); range.setEnd(t, 3)
      Object.defineProperty(range, 'getClientRects', {
        value: () => [{ left: 0, top: 0, width: 50, height: 12, right: 50, bottom: 12 }]
      })

      const loc = selectionToPdfLocator(range, pageEl1, vp1 as never, 1)!
      const pageEl2 = makePageEl({ left: 0, top: 0, width: 800, height: 1200 })
      const vp2 = makeViewport({ width: 800, height: 1200, scale: 2 })
      const screenRects = pdfLocatorToScreenRects(loc, pageEl2, vp2 as never)
      expect(screenRects).toEqual([{ left: 0, top: 0, width: 100, height: 24 }])
    })

    it('filters out client rects with zero or negative width/height', () => {
      const pageEl = makePageEl({ left: 0, top: 0, width: 400, height: 600 })
      pageEl.className = 'react-pdf__Page'
      const viewport = makeViewport({ width: 400, height: 600, scale: 1 })
      const text = document.createTextNode('xyz')
      pageEl.appendChild(text)
      const range = document.createRange()
      range.setStart(text, 0); range.setEnd(text, 3)
      Object.defineProperty(range, 'getClientRects', {
        value: () => [
          { left: 0, top: 0, width: 0, height: 10, right: 0, bottom: 10 },     // zero width
          { left: 0, top: 0, width: 10, height: 0, right: 10, bottom: 0 },     // zero height
          { left: 0, top: 0, width: 10, height: 10, right: 10, bottom: 10 }    // valid
        ]
      })
      const result = selectionToPdfLocator(range, pageEl, viewport as never, 1)
      expect(result?.rects.length).toBe(1)
    })
  })

  describe('pdfLocatorToScreenRects', () => {
    it('renders saved rects relative to the page element in CSS pixels', () => {
      const pageEl = makePageEl({ left: 50, top: 100, width: 400, height: 600 })
      const vp = makeViewport({ width: 400, height: 600, scale: 1 })
      const screen = pdfLocatorToScreenRects(
        { page: 1, rects: [{ x: 10, y: 565, w: 100, h: 15 }] },
        pageEl, vp as never
      )
      expect(screen).toEqual([{ left: 10, top: 20, width: 100, height: 15 }])
    })
  })
})
