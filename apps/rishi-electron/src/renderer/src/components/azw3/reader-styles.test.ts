import { describe, it, expect } from 'vitest'
import { injectReaderStyles, READER_CSS, READER_STYLE_ID } from './reader-styles'

function blankDoc(): Document {
  return new DOMParser().parseFromString(
    '<html><head></head><body></body></html>',
    'text/html'
  )
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
})
