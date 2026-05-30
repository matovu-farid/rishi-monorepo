import { describe, it, expect } from 'vitest'
import { expandToLineMates } from './expandToLineMates'
import {
  DEFAULT_FOOTER_MASK_OPTIONS,
  type FooterMask,
  type PageScanInput
} from '../buildFooterMask'

const VIEWPORT_HEIGHT = 600

const makeItem = (it: { str: string; y: number }): any => ({
  str: it.str,
  dir: 'ltr',
  width: Math.max(10, it.str.length * 5),
  height: 12,
  transform: [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: true
})

const makePage = (
  pageNumber: number,
  items: { str: string; y: number }[]
): PageScanInput => ({
  pageNumber,
  content: { items: items.map(makeItem), styles: {} as any } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

describe('expandToLineMates', () => {
  it('expands a single flagged item to all baseline-mates on the same page', () => {
    // Page 1: items 0,1,2 share y=30 (footer baseline); item 3 is body at y=400.
    // Only item 0 is in the input mask. Expected: items 0,1,2 all flagged
    // after expansion; item 3 is not.
    const page = makePage(1, [
      { str: '2', y: 30 },
      { str: '|', y: 30 },
      { str: 'Chapter 1: Introduction', y: 30 },
      { str: 'body content', y: 400 }
    ])
    const input: FooterMask = new Map([[1, new Set([0])]])
    const out = expandToLineMates(input, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    expect(out.get(1)?.has(0)).toBe(true)
    expect(out.get(1)?.has(1)).toBe(true)
    expect(out.get(1)?.has(2)).toBe(true)
    expect(out.get(1)?.has(3)).toBeFalsy()
  })

  it('does not pull in items outside the y-bin tolerance', () => {
    // Item 0 at y=30 is flagged. Item 1 at y=80 is too far (>yBinPct band).
    const page = makePage(1, [
      { str: '2', y: 30 },
      { str: 'subheading well above the footer line', y: 80 },
      { str: 'body', y: 400 }
    ])
    const input: FooterMask = new Map([[1, new Set([0])]])
    const out = expandToLineMates(input, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    expect(out.get(1)?.has(0)).toBe(true)
    expect(out.get(1)?.has(1)).toBeFalsy()
  })

  it('returns an empty mask unchanged', () => {
    const out = expandToLineMates(new Map(), [makePage(1, [])], DEFAULT_FOOTER_MASK_OPTIONS)
    expect(out.size).toBe(0)
  })

  it('is idempotent (running twice yields the same result)', () => {
    const page = makePage(1, [
      { str: '2', y: 30 },
      { str: 'Chapter 1: Intro', y: 30 }
    ])
    const input: FooterMask = new Map([[1, new Set([0])]])
    const once = expandToLineMates(input, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    const twice = expandToLineMates(once, [page], DEFAULT_FOOTER_MASK_OPTIONS)
    expect([...(twice.get(1) ?? [])].sort()).toEqual([...(once.get(1) ?? [])].sort())
  })
})
