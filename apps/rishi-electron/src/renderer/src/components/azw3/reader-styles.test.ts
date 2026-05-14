import { describe, it, expect } from 'vitest'
import { injectReaderStyles, READER_CSS, READER_STYLE_ID } from './reader-styles'

function blankDoc(): Document {
  return new DOMParser().parseFromString('<html><head></head><body></body></html>', 'text/html')
}

describe('injectReaderStyles', () => {
  it('appends a style element with the reader CSS', () => {
    const doc = blankDoc()
    const el = injectReaderStyles(doc)
    expect(el).toBeTruthy()
    expect(el!.id).toBe(READER_STYLE_ID)
    expect(el!.textContent).toBe(READER_CSS)
    expect(doc.head.querySelector(`#${READER_STYLE_ID}`)).toBeTruthy()
  })

  it('is idempotent — second call reuses the same element', () => {
    const doc = blankDoc()
    const a = injectReaderStyles(doc)
    const b = injectReaderStyles(doc)
    expect(a).toBe(b)
    expect(doc.head.querySelectorAll('style').length).toBe(1)
  })

  it('returns null when the document has no head', () => {
    expect(injectReaderStyles(undefined as unknown as Document)).toBeNull()
  })
})

describe('READER_CSS', () => {
  it('contains the load-bearing rules', () => {
    expect(READER_CSS).toMatch(/column-count:\s*2/)
    expect(READER_CSS).toMatch(/padding:\s*3rem/)
    expect(READER_CSS).toMatch(/\.rishi-tts-active/)
  })

  // Viewport-snapped pagination: the body must be locked to a single
  // viewport so column-fill: auto creates new columns horizontally when
  // content overflows vertically. The renderer drives `scrollLeft` in
  // viewport-wide steps to flip pages.
  it('locks the body to a single viewport (height: 100vh)', () => {
    expect(READER_CSS).toMatch(/height:\s*100vh/)
  })

  // Regression: column-fill: balance (the previous default) would even out
  // the two columns and limit overflow to one viewport, breaking horizontal
  // pagination. column-fill: auto is what makes the columns flow horizontally
  // beyond the viewport so we can scroll page-by-page.
  it('sets column-fill: auto so columns flow horizontally instead of balancing', () => {
    expect(READER_CSS).toMatch(/column-fill:\s*auto/)
  })

  // The visible column-rule gutter was removed alongside the switch to
  // viewport pagination — the rule is also drawn after the visible viewport
  // for off-screen columns, leading to visual artifacts on page turns.
  it('does not draw a visible column-rule between columns', () => {
    expect(READER_CSS).not.toMatch(/column-rule:/)
  })

  it('collapses single-child wrapper divs with display: contents', () => {
    expect(READER_CSS).toMatch(/body\s*>\s*div:only-child\s*\{[^}]*display:\s*contents/)
  })
})
