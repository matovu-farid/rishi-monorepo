import { describe, it, expect } from 'vitest'
import { computeHighlightClickPosition } from './highlightClickPosition'

function makeIframe(rect: Partial<DOMRect>): HTMLElement {
  return {
    getBoundingClientRect: () => ({ left: 0, top: 0, ...rect }) as DOMRect
  } as unknown as HTMLElement
}

function makeEventWithIframeTarget(
  iframe: HTMLElement,
  clientX: number,
  clientY: number
): MouseEvent {
  // Simulate an SVG target inside an iframe document. `frameElement` on the
  // iframe's window points to the iframe element in the outer doc.
  const iframeWindow = { frameElement: iframe } as unknown as Window
  const iframeDoc = { defaultView: iframeWindow } as unknown as Document
  const target = { ownerDocument: iframeDoc } as unknown as Element
  return { target, clientX, clientY } as unknown as MouseEvent
}

const viewport = { innerWidth: 1000, innerHeight: 800 }

describe('computeHighlightClickPosition', () => {
  it('translates iframe-local click coords using the event target iframe', () => {
    const iframe = makeIframe({ left: 50, top: 30 })
    const e = makeEventWithIframeTarget(iframe, 200, 100)
    expect(computeHighlightClickPosition(e, null, viewport)).toEqual({ x: 250, y: 130 })
  })

  it('falls back to the provided iframe when the event target is missing an iframe', () => {
    const fallback = makeIframe({ left: 10, top: 20 })
    const target = { ownerDocument: { defaultView: {} } } as unknown as Element
    const e = { target, clientX: 5, clientY: 7 } as unknown as MouseEvent
    expect(computeHighlightClickPosition(e, fallback, viewport)).toEqual({ x: 15, y: 27 })
  })

  it('returns mid-viewport when no event is provided', () => {
    expect(computeHighlightClickPosition(undefined, null, viewport)).toEqual({ x: 500, y: 400 })
  })

  it('returns mid-viewport when no iframe can be resolved', () => {
    const e = { target: null, clientX: 100, clientY: 100 } as unknown as MouseEvent
    expect(computeHighlightClickPosition(e, null, viewport)).toEqual({ x: 500, y: 400 })
  })

  it('returns mid-viewport when clientX/Y are not numeric', () => {
    const iframe = makeIframe({ left: 50, top: 30 })
    const target = { ownerDocument: { defaultView: { frameElement: iframe } } } as unknown as Element
    const e = { target } as unknown as MouseEvent
    expect(computeHighlightClickPosition(e, null, viewport)).toEqual({ x: 500, y: 400 })
  })

  it('handles cross-realm event targets without using instanceof', () => {
    // The SVG target's Element constructor would differ from this window's
    // Element; the helper must not rely on `instanceof Element`. Pass a
    // plain object that quacks like an Element to prove the duck-typed path.
    const iframe = makeIframe({ left: 100, top: 60 })
    const e = makeEventWithIframeTarget(iframe, 400, 200)
    expect(computeHighlightClickPosition(e, null, viewport)).toEqual({ x: 500, y: 260 })
  })
})
