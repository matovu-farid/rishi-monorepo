// @vitest-environment happy-dom
import { describe, it, expect, beforeEach } from 'vitest'
import { resolveParagraphElement } from './resolve-paragraph'

function makeBody(html: string): HTMLElement {
  // Test-only — DOMParser produces a sandboxed document.
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, 'text/html')
  // Move parsed children into the live document.body so the helper sees them
  // in the same DOM the test expects.
  while (document.body.firstChild) document.body.removeChild(document.body.firstChild)
  for (const child of Array.from(doc.body.childNodes)) {
    document.body.appendChild(document.adoptNode(child))
  }
  return document.body
}

describe('resolveParagraphElement', () => {
  beforeEach(() => {
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild)
  })

  it('returns null when body is null/undefined', () => {
    expect(resolveParagraphElement(null, 0)).toBeNull()
    expect(resolveParagraphElement(undefined, 0)).toBeNull()
  })

  it('returns the Nth paragraph-like element in the body', () => {
    const body = makeBody('<p>A</p><p>B</p><p>C</p>')
    expect(resolveParagraphElement(body, 0)?.textContent).toBe('A')
    expect(resolveParagraphElement(body, 1)?.textContent).toBe('B')
    expect(resolveParagraphElement(body, 2)?.textContent).toBe('C')
  })

  it('returns null when the index is out of range', () => {
    const body = makeBody('<p>only</p>')
    expect(resolveParagraphElement(body, 5)).toBeNull()
  })

  it('matches heading and list-item elements as candidates', () => {
    const body = makeBody('<h1>Title</h1><p>Body</p><li>Item</li>')
    expect(resolveParagraphElement(body, 0)?.tagName.toLowerCase()).toBe('h1')
    expect(resolveParagraphElement(body, 1)?.tagName.toLowerCase()).toBe('p')
    expect(resolveParagraphElement(body, 2)?.tagName.toLowerCase()).toBe('li')
  })
})
