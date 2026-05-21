import {
  parseOutgoing,
  serializeIncoming,
  flattenOutline,
  type PdfWebViewIncomingMessage,
  type PdfOutlineItem,
} from '@/components/pdf/pdf-webview-bridge'

describe('parseOutgoing', () => {
  it('returns null for non-JSON input', () => {
    expect(parseOutgoing('not json')).toBeNull()
  })

  it('returns null when type is missing', () => {
    expect(parseOutgoing('{"foo": "bar"}')).toBeNull()
  })

  it('returns null for unknown types', () => {
    expect(parseOutgoing('{"type": "mystery"}')).toBeNull()
  })

  it('parses ready', () => {
    expect(parseOutgoing('{"type":"ready"}')).toEqual({ type: 'ready' })
  })

  it('parses loaded with outline', () => {
    const raw = JSON.stringify({
      type: 'loaded',
      numPages: 200,
      outline: [
        { title: 'Chapter 1', pageNumber: 5, children: [] },
        { title: 'Chapter 2', pageNumber: 50, children: [
          { title: '2.1', pageNumber: 52, children: [] },
        ]},
      ],
    })
    const parsed = parseOutgoing(raw)
    expect(parsed?.type).toBe('loaded')
    if (parsed?.type === 'loaded') {
      expect(parsed.numPages).toBe(200)
      expect(parsed.outline).toHaveLength(2)
      expect(parsed.outline[1].children).toHaveLength(1)
    }
  })

  it('loaded with missing numPages is rejected', () => {
    expect(parseOutgoing('{"type":"loaded","outline":[]}')).toBeNull()
  })

  it('parses pageChanged with offset', () => {
    const parsed = parseOutgoing('{"type":"pageChanged","pageNumber":5,"offset":120}')
    expect(parsed).toEqual({ type: 'pageChanged', pageNumber: 5, offset: 120 })
  })

  it('parses pageChanged defaulting offset to 0', () => {
    const parsed = parseOutgoing('{"type":"pageChanged","pageNumber":5}')
    expect(parsed).toEqual({ type: 'pageChanged', pageNumber: 5, offset: 0 })
  })

  it('parses selection with locator + anchor', () => {
    const raw = JSON.stringify({
      type: 'selection',
      pageNumber: 5,
      text: 'hello world',
      locator: { page: 5, rects: [{ x: 1, y: 2, w: 3, h: 4 }] },
      anchor: { x: 100, y: 200 },
    })
    const parsed = parseOutgoing(raw)
    expect(parsed?.type).toBe('selection')
    if (parsed?.type === 'selection') {
      expect(parsed.text).toBe('hello world')
      expect(parsed.locator.rects).toHaveLength(1)
      expect(parsed.anchor).toEqual({ x: 100, y: 200 })
    }
  })

  it('selection without locator is rejected', () => {
    const raw = JSON.stringify({ type: 'selection', pageNumber: 5, text: 'x', anchor: { x: 0, y: 0 } })
    expect(parseOutgoing(raw)).toBeNull()
  })

  it('parses selectionCleared', () => {
    expect(parseOutgoing('{"type":"selectionCleared"}')).toEqual({ type: 'selectionCleared' })
  })

  it('parses pageText response', () => {
    const raw = JSON.stringify({
      type: 'pageText',
      requestId: 'req-1',
      pageNumber: 3,
      paragraphs: [
        { index: '30001', text: 'first paragraph' },
        { index: '30002', text: 'second paragraph' },
      ],
    })
    const parsed = parseOutgoing(raw)
    expect(parsed?.type).toBe('pageText')
    if (parsed?.type === 'pageText') {
      expect(parsed.paragraphs).toHaveLength(2)
      expect(parsed.requestId).toBe('req-1')
    }
  })

  it('pageText with missing requestId is rejected', () => {
    expect(parseOutgoing('{"type":"pageText","pageNumber":1,"paragraphs":[]}')).toBeNull()
  })

  it('parses highlightTapped', () => {
    const raw = JSON.stringify({
      type: 'highlightTapped',
      highlightId: 'h-1',
      anchor: { x: 100, y: 200 },
    })
    expect(parseOutgoing(raw)).toEqual({
      type: 'highlightTapped',
      highlightId: 'h-1',
      anchor: { x: 100, y: 200 },
    })
  })

  it('parses error', () => {
    expect(parseOutgoing('{"type":"error","message":"oops"}')).toEqual({
      type: 'error',
      message: 'oops',
    })
  })

  it('error with no message defaults to "unknown"', () => {
    expect(parseOutgoing('{"type":"error"}')).toEqual({ type: 'error', message: 'unknown' })
  })
})

describe('serializeIncoming', () => {
  it('serializes load command', () => {
    const msg: PdfWebViewIncomingMessage = { type: 'load', data: 'base64data' }
    expect(JSON.parse(serializeIncoming(msg))).toEqual(msg)
  })

  it('serializes goToPage command', () => {
    const msg: PdfWebViewIncomingMessage = { type: 'goToPage', page: 5, offset: 120 }
    expect(JSON.parse(serializeIncoming(msg))).toEqual(msg)
  })

  it('serializes addHighlight command', () => {
    const msg: PdfWebViewIncomingMessage = {
      type: 'addHighlight',
      id: 'h-1',
      color: 'yellow',
      locator: { page: 1, rects: [{ x: 0, y: 0, w: 1, h: 1 }] },
    }
    expect(JSON.parse(serializeIncoming(msg))).toEqual(msg)
  })

  it('serializes setHighlights command', () => {
    const msg: PdfWebViewIncomingMessage = {
      type: 'setHighlights',
      highlights: [
        { id: 'h-1', color: 'yellow', locator: { page: 1, rects: [] } },
        { id: 'h-2', color: 'green', locator: { page: 2, rects: [] } },
      ],
    }
    expect(JSON.parse(serializeIncoming(msg))).toEqual(msg)
  })

  it('serializes getPageText command with requestId', () => {
    const msg: PdfWebViewIncomingMessage = {
      type: 'getPageText',
      requestId: 'req-1',
      pageNumber: 3,
    }
    expect(JSON.parse(serializeIncoming(msg))).toEqual(msg)
  })
})

describe('flattenOutline', () => {
  it('flattens nested outline preserving depth', () => {
    const outline: PdfOutlineItem[] = [
      { title: 'A', pageNumber: 1, children: [
        { title: 'A.1', pageNumber: 2, children: [
          { title: 'A.1.a', pageNumber: 3, children: [] },
        ]},
        { title: 'A.2', pageNumber: 5, children: [] },
      ]},
      { title: 'B', pageNumber: 10, children: [] },
    ]
    expect(flattenOutline(outline)).toEqual([
      { title: 'A', pageNumber: 1, depth: 0 },
      { title: 'A.1', pageNumber: 2, depth: 1 },
      { title: 'A.1.a', pageNumber: 3, depth: 2 },
      { title: 'A.2', pageNumber: 5, depth: 1 },
      { title: 'B', pageNumber: 10, depth: 0 },
    ])
  })

  it('returns an empty array for empty input', () => {
    expect(flattenOutline([])).toEqual([])
  })

  it('skips malformed outline entries (sanitized at parse, but defensive)', () => {
    expect(flattenOutline([{ title: 'X', pageNumber: null, children: [] }])).toEqual([
      { title: 'X', pageNumber: null, depth: 0 },
    ])
  })
})
