import { describe, it, expect } from 'vitest'
import { detectFootnoteItems } from './detectFootnoteItems'

// transform = [a,b,c,d, x, y]; y is the PDF baseline (grows upward).
const makeItem = (
  str: string,
  y: number,
  opts: { height?: number; x?: number; hasEOL?: boolean } = {}
): any => ({
  str,
  dir: 'ltr',
  width: Math.max(10, str.length * 5),
  height: opts.height ?? 10.5,
  transform: [12, 0, 0, 12, opts.x ?? 60, y],
  fontName: 'g_d0_f1',
  hasEOL: opts.hasEOL ?? true
})

describe('detectFootnoteItems', () => {
  it('flags a smaller-font block separated from the body by an oversized gap', () => {
    const items = [
      makeItem('Body line one long enough to count as real body text here.', 400),
      makeItem('Body line two long enough to count as real body text here.', 387),
      makeItem('Body line three long enough to count as real body text.', 374),
      // ~290px gap, smaller font -> footnote
      makeItem('1 Brendan Burns et al., footnote first line.', 80, { height: 8 }),
      makeItem('continued footnote line two.', 68, { height: 8 })
    ]
    expect([...detectFootnoteItems(items)].sort((a, b) => a - b)).toEqual([3, 4])
  })

  it('does NOT flag a mid-page superscript marker (small font but above body bottom)', () => {
    const items = [
      makeItem('Body line one long enough to count as real body text here.', 400),
      makeItem('9', 403, { height: 6, x: 360 }), // superscript, mid-page
      makeItem('Body line two long enough to count as real body text here.', 387),
      makeItem('Body line three long enough to count as real body text.', 374)
    ]
    expect([...detectFootnoteItems(items)]).toEqual([])
  })

  it('does NOT flag small text that sits right under the body (gap too small)', () => {
    const items = [
      makeItem('Body line one long enough to count as real body text here.', 400),
      makeItem('Body line two long enough to count as real body text here.', 387),
      makeItem('Body line three long enough to count as real body text.', 374),
      makeItem('a small caption immediately below the body', 366, { height: 8 })
    ]
    expect([...detectFootnoteItems(items)]).toEqual([])
  })

  it('does NOT flag body-sized text below a gap (requires a smaller font)', () => {
    const items = [
      makeItem('Body line one long enough to count as real body text here.', 400),
      makeItem('Body line two long enough to count as real body text here.', 387),
      makeItem('Body line three long enough to count as real body text.', 374),
      makeItem('Same-size text far below, e.g. a continued block.', 80) // height 10.5
    ]
    expect([...detectFootnoteItems(items)]).toEqual([])
  })

  it('returns empty when there is no small-font text', () => {
    const items = [
      makeItem('Body line one.', 400),
      makeItem('Body line two.', 387),
      makeItem('Body line three.', 374)
    ]
    expect([...detectFootnoteItems(items)]).toEqual([])
  })

  it('ignores non-text marked-content items', () => {
    const items = [
      { type: 'beginMarkedContent' },
      makeItem('Body line one long enough to count as real body text here.', 400),
      makeItem('Body line two long enough to count as real body text here.', 387),
      makeItem('Body line three long enough to count as real body text.', 374),
      makeItem('1 footnote text below an oversized gap.', 80, { height: 8 })
    ]
    expect([...detectFootnoteItems(items)]).toEqual([4])
  })
})
