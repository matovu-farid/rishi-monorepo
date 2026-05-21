/**
 * Outline (TOC) integration: verifies that a `loaded` message from the
 * WebView parses into a usable outline tree and that flattening
 * preserves the depth for the TOC drawer UI.
 *
 * The actual pdfjs `pdfDoc.getOutline()` call happens inside the
 * WebView; here we drive the bridge parser with realistic shapes.
 */

import { parseOutgoing, flattenOutline } from '@/components/pdf/pdf-webview-bridge'

describe('PDF outline parsing', () => {
  it('parses a flat outline', () => {
    const raw = JSON.stringify({
      type: 'loaded',
      numPages: 200,
      outline: [
        { title: 'Cover', pageNumber: 1, children: [] },
        { title: 'Contents', pageNumber: 3, children: [] },
        { title: 'Chapter 1', pageNumber: 9, children: [] },
      ],
    })
    const parsed = parseOutgoing(raw)
    expect(parsed?.type).toBe('loaded')
    if (parsed?.type !== 'loaded') return
    expect(parsed.outline).toHaveLength(3)
    expect(parsed.outline.map((i) => i.pageNumber)).toEqual([1, 3, 9])
  })

  it('parses a nested outline (textbook with sections)', () => {
    const raw = JSON.stringify({
      type: 'loaded',
      numPages: 500,
      outline: [
        {
          title: 'Part I',
          pageNumber: 1,
          children: [
            {
              title: 'Chapter 1',
              pageNumber: 10,
              children: [
                { title: '1.1', pageNumber: 12, children: [] },
                { title: '1.2', pageNumber: 25, children: [] },
              ],
            },
          ],
        },
      ],
    })
    const parsed = parseOutgoing(raw)
    if (parsed?.type !== 'loaded') throw new Error('expected loaded')
    expect(parsed.outline[0].children[0].children).toHaveLength(2)

    const flat = flattenOutline(parsed.outline)
    expect(flat).toEqual([
      { title: 'Part I', pageNumber: 1, depth: 0 },
      { title: 'Chapter 1', pageNumber: 10, depth: 1 },
      { title: '1.1', pageNumber: 12, depth: 2 },
      { title: '1.2', pageNumber: 25, depth: 2 },
    ])
  })

  it('accepts an empty outline (PDF without bookmarks)', () => {
    const parsed = parseOutgoing(JSON.stringify({ type: 'loaded', numPages: 50, outline: [] }))
    if (parsed?.type !== 'loaded') throw new Error('expected loaded')
    expect(parsed.outline).toEqual([])
    expect(flattenOutline(parsed.outline)).toEqual([])
  })

  it('drops outline items missing a title (defensive sanitization)', () => {
    const raw = JSON.stringify({
      type: 'loaded',
      numPages: 10,
      outline: [
        { title: 'Valid', pageNumber: 1, children: [] },
        { pageNumber: 2, children: [] }, // missing title
        { title: 123, pageNumber: 3, children: [] }, // wrong type
      ],
    })
    const parsed = parseOutgoing(raw)
    if (parsed?.type !== 'loaded') throw new Error('expected loaded')
    expect(parsed.outline).toHaveLength(1)
    expect(parsed.outline[0].title).toBe('Valid')
  })

  it('preserves unresolvable destinations as pageNumber: null', () => {
    // Some PDFs reference named destinations that fail to resolve. The
    // WebView reports those as pageNumber: null so the TOC row can
    // still render (just disabled).
    const raw = JSON.stringify({
      type: 'loaded',
      numPages: 10,
      outline: [{ title: 'Broken Bookmark', pageNumber: null, children: [] }],
    })
    const parsed = parseOutgoing(raw)
    if (parsed?.type !== 'loaded') throw new Error('expected loaded')
    expect(parsed.outline[0].pageNumber).toBeNull()
  })
})
