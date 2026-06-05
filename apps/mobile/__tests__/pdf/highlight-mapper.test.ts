import { toHighlightShape } from '@/lib/pdf/highlight-mapper'

describe('toHighlightShape', () => {
  it('parses a pdf: cfiRange into the overlay shape', () => {
    const out = toHighlightShape({
      id: 'h1',
      cfiRange: 'pdf:' + JSON.stringify({ page: 3, rects: [{ x: 1, y: 2, w: 3, h: 4 }] }),
      color: 'green',
    })
    expect(out).toEqual({
      id: 'h1',
      page: 3,
      color: 'green',
      rects: [{ x: 1, y: 2, w: 3, h: 4 }],
    })
  })

  it('returns null for EPUB highlights (non-pdf: prefix)', () => {
    const out = toHighlightShape({
      id: 'h2',
      cfiRange: 'epubcfi(/6/4!/2/16/1:2)',
      color: 'yellow',
    })
    expect(out).toBeNull()
  })

  it('returns null for deleted rows', () => {
    const out = toHighlightShape({
      id: 'h3',
      cfiRange: 'pdf:{"page":1,"rects":[]}',
      color: 'yellow',
      isDeleted: 1,
    })
    expect(out).toBeNull()
  })

  it('falls back to yellow when color is invalid', () => {
    const out = toHighlightShape({
      id: 'h4',
      cfiRange: 'pdf:{"page":1,"rects":[]}',
      color: 'orange',
    })
    expect(out?.color).toBe('yellow')
  })

  it('returns null for malformed JSON', () => {
    expect(toHighlightShape({
      id: 'h5',
      cfiRange: 'pdf:{not valid json',
      color: 'yellow',
    })).toBeNull()
  })
})
