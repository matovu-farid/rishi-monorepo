import { describe, it, expect } from 'vitest'
import { orderTextItemsForReading } from './orderTextItemsForReading'

// transform = [a, b, c, d, e, f] where e = x (left), f = y (baseline).
const makeItem = (
  str: string,
  x: number,
  y: number,
  opts: { hasEOL?: boolean; height?: number; width?: number } = {}
): any => ({
  str,
  dir: 'ltr',
  width: opts.width ?? Math.max(10, str.length * 5),
  height: opts.height ?? 12,
  transform: [12, 0, 0, 12, x, y],
  fontName: 'g_d0_f1',
  hasEOL: opts.hasEOL ?? true
})

const texts = (items: any[]): string[] =>
  orderTextItemsForReading(items).map((e) => e.item.str)

const indices = (items: any[]): number[] =>
  orderTextItemsForReading(items).map((e) => e.index)

describe('orderTextItemsForReading', () => {
  it('orders a single-column page top-to-bottom even when the stream emits the footnote first', () => {
    // Mirrors "Kubernetes Up & Running" p.23: footnote block (low y) emitted
    // FIRST in the content stream, then body (high->low y), then page number.
    const items = [
      makeItem('Brendan Burns et al., footnote line', 60, 75), // footnote (stream idx 0)
      makeItem('CHAPTER 1', 60, 560),
      makeItem('Kubernetes is an open source orchestrator', 60, 410),
      makeItem('Since its introduction in 2014', 60, 360),
      makeItem('1', 60, 43) // page number (visually very bottom)
    ]
    expect(texts(items)).toEqual([
      'CHAPTER 1',
      'Kubernetes is an open source orchestrator',
      'Since its introduction in 2014',
      'Brendan Burns et al., footnote line',
      '1'
    ])
  })

  it('preserves the original stream index for each item (footer-mask compatibility)', () => {
    const items = [
      makeItem('footnote', 60, 75), // idx 0
      makeItem('body top', 60, 560), // idx 1
      makeItem('body mid', 60, 410) // idx 2
    ]
    // Reading order is body top, body mid, footnote -> original indices 1,2,0.
    expect(indices(items)).toEqual([1, 2, 0])
  })

  it('keeps a superscript marker within its line instead of hoisting it above', () => {
    // The superscript "9" sits at a raised baseline (y=388.5) between the body
    // line at y=397.6 and the line it belongs to at y=385.0. A naive y-sort
    // would read "9" before that line; line-bucketing must keep it after.
    const items = [
      makeItem('It was originally developed by Google', 60, 397.6),
      makeItem('scalable reliable systems via application oriented APIs', 60, 385.0, {
        width: 300
      }),
      makeItem('9', 365, 388.5, { height: 8, width: 6 }) // superscript at end of the 385 line
    ]
    const out = texts(items).join(' | ')
    expect(out.indexOf('application oriented APIs')).toBeLessThan(out.indexOf('9'))
    expect(out.indexOf('It was originally')).toBeLessThan(out.indexOf('application oriented'))
  })

  it('reads a two-column page left column fully before the right column (no interleaving)', () => {
    // Left column at x=50, right column at x=350, clear gutter between ~250-350.
    // Stream emits them interleaved to prove we re-sort by column, not stream.
    const items = [
      makeItem('R line 1', 350, 500, { width: 200 }),
      makeItem('L line 1', 50, 500, { width: 200 }),
      makeItem('R line 2', 350, 480, { width: 200 }),
      makeItem('L line 2', 50, 480, { width: 200 }),
      makeItem('R line 3', 350, 460, { width: 200 }),
      makeItem('L line 3', 50, 460, { width: 200 })
    ]
    expect(texts(items)).toEqual([
      'L line 1',
      'L line 2',
      'L line 3',
      'R line 1',
      'R line 2',
      'R line 3'
    ])
  })

  it('skips non-text marked-content items but keeps stream indices stable', () => {
    const items = [
      { type: 'beginMarkedContent' }, // idx 0 (non-text)
      makeItem('top', 60, 500), // idx 1
      makeItem('bottom', 60, 300) // idx 2
    ]
    expect(indices(items)).toEqual([1, 2])
    expect(texts(items)).toEqual(['top', 'bottom'])
  })
})
