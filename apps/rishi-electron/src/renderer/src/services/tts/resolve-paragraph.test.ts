import { describe, it, expect, beforeEach } from 'vitest'
import { resolveParagraphElement } from './index'
import { registerEpubFrame, clearEpubFrame } from '@/modules/pageCapture/epubFrameRegistry'

function makeIframeWithBody(html: string): HTMLIFrameElement {
  const iframe = document.createElement('iframe')
  document.body.appendChild(iframe)
  // Safe: test-only, controlled HTML in sandboxed jsdom — not user input
  iframe.contentDocument!.open()
  iframe.contentDocument!.write(`<body>${html}</body>`)
  iframe.contentDocument!.close()
  return iframe
}

describe('resolveParagraphElement', () => {
  beforeEach(() => {
    clearEpubFrame()
    document.body.innerHTML = ''
  })

  it('returns null when no EPUB iframe is registered', () => {
    expect(resolveParagraphElement(0)).toBeNull()
  })

  it('returns the Nth paragraph-like element in the iframe body', () => {
    const iframe = makeIframeWithBody('<p>A</p><p>B</p><p>C</p>')
    registerEpubFrame(iframe)
    expect(resolveParagraphElement(0)?.textContent).toBe('A')
    expect(resolveParagraphElement(1)?.textContent).toBe('B')
    expect(resolveParagraphElement(2)?.textContent).toBe('C')
  })

  it('returns null when the index is out of range', () => {
    const iframe = makeIframeWithBody('<p>only</p>')
    registerEpubFrame(iframe)
    expect(resolveParagraphElement(5)).toBeNull()
  })

  it('matches heading and list-item elements as candidates', () => {
    const iframe = makeIframeWithBody('<h1>Title</h1><p>Body</p><li>Item</li>')
    registerEpubFrame(iframe)
    expect(resolveParagraphElement(0)?.tagName.toLowerCase()).toBe('h1')
    expect(resolveParagraphElement(1)?.tagName.toLowerCase()).toBe('p')
    expect(resolveParagraphElement(2)?.tagName.toLowerCase()).toBe('li')
  })
})
