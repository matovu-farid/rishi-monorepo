import { describe, it, expect } from 'vitest'
import { findParagraphElement, parseParagraphIndex } from './highlight'

function docOf(html: string): Document {
  return new DOMParser().parseFromString(`<html><body>${html}</body></html>`, 'text/html')
}

describe('parseParagraphIndex', () => {
  it('parses a well-formed azw3 index', () => {
    expect(parseParagraphIndex('azw3-3-7')).toEqual({ chapter: 3, paragraph: 7 })
  })
  it('rejects strings from other formats', () => {
    expect(parseParagraphIndex('epub-1-2')).toBeNull()
    expect(parseParagraphIndex('mobi-0-0')).toBeNull()
    expect(parseParagraphIndex('azw3-x-y')).toBeNull()
    expect(parseParagraphIndex('')).toBeNull()
  })
})

describe('findParagraphElement', () => {
  it('returns the i-th text-bearing paragraph and skips empty ones', () => {
    const doc = docOf(`
      <p>first</p>
      <p>   </p>
      <h2>heading</h2>
      <p></p>
      <blockquote>quoted</blockquote>
    `)
    expect(findParagraphElement(doc, 0)?.textContent?.trim()).toBe('first')
    expect(findParagraphElement(doc, 1)?.textContent?.trim()).toBe('heading')
    expect(findParagraphElement(doc, 2)?.textContent?.trim()).toBe('quoted')
  })

  it('returns null when the index exceeds the visible-paragraph count', () => {
    const doc = docOf(`<p>only</p>`)
    expect(findParagraphElement(doc, 5)).toBeNull()
  })

  it('returns null for a missing document', () => {
    expect(findParagraphElement(null, 0)).toBeNull()
    expect(findParagraphElement(undefined, 0)).toBeNull()
  })
})
