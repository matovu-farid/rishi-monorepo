import { describe, it, expect, beforeAll, vi } from 'vitest'
import { makeCoverSection, stripKindleResourceLinks } from './parser'

beforeAll(() => {
  if (typeof URL.createObjectURL !== 'function') {
    Object.assign(URL, {
      createObjectURL: vi.fn(() => 'blob:test/fake'),
      revokeObjectURL: vi.fn()
    })
  }
})

describe('makeCoverSection', () => {
  it('builds a section whose load() returns a blob URL', async () => {
    const cover = new Blob([new Uint8Array([0xff])], { type: 'image/jpeg' })
    const section = makeCoverSection(cover)
    expect(section.id).toBe('azw3-cover')
    expect(section.virtualGroupId).toBe('azw3-cover')
    const url = await section.load!()
    expect(url).toMatch(/^blob:/)
  })

  it('createDocument returns a doc with an <img> cover element', async () => {
    const cover = new Blob([new Uint8Array([0xff])], { type: 'image/jpeg' })
    const section = makeCoverSection(cover)
    const doc = await section.createDocument!()
    const img = doc.querySelector('img')
    expect(img).not.toBeNull()
    expect(img!.getAttribute('alt')).toBe('Cover')
    expect(img!.getAttribute('src')).toMatch(/^blob:/)
  })

  it('caches the blob URL across repeated load() calls', async () => {
    const cover = new Blob([new Uint8Array([0xff])])
    const section = makeCoverSection(cover)
    const a = await section.load!()
    const b = await section.load!()
    expect(a).toBe(b)
  })
})

describe('stripKindleResourceLinks', () => {
  function docOf(body: string): Document {
    return new DOMParser().parseFromString(
      `<html><head></head><body>${body}</body></html>`,
      'text/html'
    )
  }

  it('removes <link> tags with kindle: hrefs', () => {
    // Build the link nodes via DOM API so happy-dom doesn't try to fetch
    // them as stylesheets during parseFromString.
    const doc = new DOMParser().parseFromString(
      '<html><head></head><body></body></html>',
      'text/html'
    )
    const bad = doc.createElement('link')
    bad.setAttribute('rel', 'stylesheet')
    bad.setAttribute('href', 'kindle:flow:0001?mime=text/css')
    const ok = doc.createElement('link')
    ok.setAttribute('rel', 'preload')
    ok.setAttribute('href', 'data:text/css,body%7B%7D')
    doc.head.append(bad, ok)

    const removed = stripKindleResourceLinks(doc)
    expect(removed).toBe(1)
    expect(doc.querySelectorAll('link').length).toBe(1)
    expect(doc.querySelector('link')!.getAttribute('href')).toMatch(/^data:/)
  })

  it('removes <img> tags with kindle: src that foliate failed to rewrite', () => {
    const doc = docOf(
      '<img src="kindle:embed:0002"/><img src="blob:rishi/already-rewritten"/>'
    )
    const removed = stripKindleResourceLinks(doc)
    expect(removed).toBe(1)
    expect(doc.querySelectorAll('img').length).toBe(1)
    expect(doc.querySelector('img')!.getAttribute('src')).toMatch(/^blob:/)
  })

  it('returns 0 and leaves the doc untouched when no kindle: refs exist', () => {
    const doc = docOf('<p>plain text</p><img src="https://cdn/img.png"/>')
    expect(stripKindleResourceLinks(doc)).toBe(0)
    expect(doc.querySelectorAll('img').length).toBe(1)
  })
})
