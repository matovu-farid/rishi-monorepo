import { describe, it, expect } from 'vitest'
import {
  buildFooterMask,
  normalizeFooterToken,
  MIN_PAGES_FOR_DETECTION,
  DEFAULT_FOOTER_MASK_OPTIONS,
  type PageScanInput
} from './buildFooterMask'

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------
//
// pdfjs-dist TextItem.transform is a 6-element matrix [a, b, c, d, e, f] where
// f (index 5) is the y-position in PDF user space (origin = bottom-left).
// We hand-roll the bits of TextContent / TextItem we actually use; everything
// else can be left undefined and the heuristic must not read it.

const VIEWPORT_HEIGHT = 600

interface FixtureItem {
  str: string
  /** y position in PDF user space (0 = bottom). */
  y: number
  /** font-size-ish, only used as a hint for paragraph threshold elsewhere. */
  height?: number
  width?: number
  /** Allow tests to inject a malformed transform (truncated, NaN, ...). */
  transform?: number[]
  hasEOL?: boolean
}

const makeItem = (it: FixtureItem): any => ({
  str: it.str,
  dir: 'ltr',
  width: it.width ?? Math.max(10, it.str.length * 5),
  height: it.height ?? 12,
  transform: it.transform ?? [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: it.hasEOL ?? true
})

const makePage = (pageNumber: number, items: FixtureItem[]): PageScanInput => ({
  pageNumber,
  content: {
    items: items.map(makeItem),
    styles: {} as any
  } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('normalizeFooterToken', () => {
  it('collapses pure numeric tokens to a numeric sentinel', () => {
    const a = normalizeFooterToken('47')
    const b = normalizeFooterToken('48')
    const c = normalizeFooterToken('123')
    expect(a).toBe(b)
    expect(b).toBe(c)
  })

  it('collapses pure roman-numeral tokens to a roman sentinel (or matches numeric class)', () => {
    const a = normalizeFooterToken('iv')
    const b = normalizeFooterToken('vii')
    expect(a).toBe(b)
  })

  it('does NOT collapse alphabetic tokens', () => {
    expect(normalizeFooterToken('Chapter')).not.toBe(normalizeFooterToken('123'))
    expect(normalizeFooterToken('Chapter')).toBe(normalizeFooterToken('Chapter'))
  })

  it('is whitespace- and case-insensitive', () => {
    expect(normalizeFooterToken('  Hello World  ')).toBe(normalizeFooterToken('hello world'))
  })

  it('collapses embedded digit runs so "Page 47" == "Page 48" == "Page 350"', () => {
    const a = normalizeFooterToken('Page 47')
    const b = normalizeFooterToken('Page 48')
    const c = normalizeFooterToken('Page 350')
    expect(a).toBe(b)
    expect(b).toBe(c)
    expect(a).toBe('page __NUM__')
  })

  it('collapses multiple embedded numbers ("47 of 350" == "48 of 350")', () => {
    expect(normalizeFooterToken('47 of 350')).toBe(normalizeFooterToken('48 of 350'))
  })

  it('does NOT collapse digits that are joined to letters without a word break', () => {
    // "chapter3" has no word boundary between "r" and "3" — leave it alone.
    expect(normalizeFooterToken('chapter3')).toBe('chapter3')
  })
})

describe('buildFooterMask', () => {
  it('returns empty Map when pages.length < MIN_PAGES_FOR_DETECTION', () => {
    expect(MIN_PAGES_FOR_DETECTION).toBeGreaterThanOrEqual(8)
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 5; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body text on page ' + p, y: 500 },
          { str: 'Page ' + p, y: 40 } // clear footer signal, but too few pages
        ])
      )
    }
    const mask = buildFooterMask(pages)
    expect(mask.size).toBe(0)
  })

  it('masks an item that repeats at the same Y on >=30% of pages', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: 'Running Footer', y: 40 } // repeats verbatim at same y
        ])
      )
    }
    const mask = buildFooterMask(pages)
    expect(mask.size).toBeGreaterThanOrEqual(8)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      expect(set, `page ${p} should have masked indices`).toBeDefined()
      // index 1 is the footer in our fixture
      expect(set!.has(1)).toBe(true)
      // index 0 is body — must NOT be masked
      expect(set!.has(0)).toBe(false)
    }
  })

  it('does NOT mask items above the bottom band', () => {
    // bottomBandPct=0.25, viewportHeight=600 => bottom band is y in [0, 150].
    // y=300 is well above the band.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: 'Running Mid-page Heading', y: 300 } // repeats but NOT in band
        ])
      )
    }
    const mask = buildFooterMask(pages)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      // Either the page is absent from the mask, or the would-be index 1 is not masked.
      if (set) expect(set.has(1)).toBe(false)
    }
  })

  it('treats numeric tokens as equivalent for repetition', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: String(p + 46), y: 40 } // "47", "48", ... — distinct strings
        ])
      )
    }
    const mask = buildFooterMask(pages)
    // Page numbers should collapse via normalizeFooterToken and trigger masking.
    let pagesWithFooterMasked = 0
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set && set.has(1)) pagesWithFooterMasked++
    }
    expect(pagesWithFooterMasked).toBeGreaterThanOrEqual(8)
  })

  it('does NOT mask body text that happens to repeat (out of bottom band)', () => {
    // Same repetition signal but at the TOP of the page (running heading).
    // The bottom-band guard means it's not a footer candidate.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Same running heading', y: 580 }, // top, outside bottom band
          { str: 'Body of page ' + p, y: 300 }
        ])
      )
    }
    const mask = buildFooterMask(pages)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set) expect(set.has(0)).toBe(false)
    }
  })

  it('does NOT mask footnote text (bottom band but unique per page)', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          // Per-page footnote: strings have stable structure but ALL unique
          // after normalisation (contain words, not just digits).
          { str: `${p}. Footnote about subject ${String.fromCharCode(64 + p)}`, y: 40 }
        ])
      )
    }
    const mask = buildFooterMask(pages)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set) expect(set.has(1)).toBe(false)
    }
  })

  it('masks the bottom-most 3 lines when 4 footer lines all repeat', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: 'Copyright 2024 Foo Corp', y: 70 }, // line 1 (highest of 4 — dropped by cap)
          { str: 'All rights reserved', y: 55 }, // line 2
          { str: 'See foo.com/terms', y: 40 }, // line 3
          { str: 'Page ' + p, y: 25 } // line 4 (lowest)
        ])
      )
    }
    const mask = buildFooterMask(pages, { maxFooterLines: 3 })
    let maskedLine1 = 0
    let maskedLine2 = 0
    let maskedLine3 = 0
    let maskedLine4 = 0
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (!set) continue
      if (set.has(1)) maskedLine1++
      if (set.has(2)) maskedLine2++
      if (set.has(3)) maskedLine3++
      if (set.has(4)) maskedLine4++
    }
    // Cap kicks in: keep the bottom-most 3 (lines 2, 3, 4); drop line 1.
    expect(maskedLine1).toBe(0)
    expect(maskedLine2).toBeGreaterThanOrEqual(8)
    expect(maskedLine3).toBeGreaterThanOrEqual(8)
    expect(maskedLine4).toBeGreaterThanOrEqual(8)
  })

  it('does NOT mask a repeating bottom-band string longer than maxCharsPerLine', () => {
    const longString = 'x'.repeat(300)
    expect(longString.length).toBeGreaterThan(DEFAULT_FOOTER_MASK_OPTIONS.maxCharsPerLine)
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: longString, y: 40 }
        ])
      )
    }
    const mask = buildFooterMask(pages)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set) expect(set.has(1)).toBe(false)
    }
  })

  it('Y binning tolerates jitter <= yBinPct of page height', () => {
    // yBinPct=0.02, viewportHeight=600 => bin width ~12. 40.0 vs 40.3 is well inside.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: 'Same Footer', y: p % 2 === 0 ? 40.3 : 40.0 } // tiny jitter
        ])
      )
    }
    const mask = buildFooterMask(pages)
    let masked = 0
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set && set.has(1)) masked++
    }
    expect(masked).toBeGreaterThanOrEqual(8)
  })

  it('Y binning rejects jitter > yBinPct', () => {
    // Same string but two very different y positions across pages (40 vs 200).
    // Since neither cluster individually crosses 30%, no mask.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: 'Same Footer', y: p <= 5 ? 40 : 200 }
        ])
      )
    }
    const mask = buildFooterMask(pages)
    // Each cluster has only 5/10 pages and only the bottom cluster is in band.
    // Even if the bottom cluster (5 pages) is >=30%, the OTHER cluster must
    // NOT count toward the same bin — that's the assertion. So pages 6..10
    // (where y=200, NOT in band) must NOT be masked.
    for (let p = 6; p <= 10; p++) {
      const set = mask.get(p)
      if (set) expect(set.has(1)).toBe(false)
    }
  })

  it('returns empty Map when fewer than 5% of items have finite transform[5]', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          // transform too short — no y at index 5
          { str: 'Body of page ' + p, y: 500, transform: [12, 0, 0, 12] as any },
          // transform with NaN at index 5
          { str: 'Garbage Footer', y: 40, transform: [12, 0, 0, 12, 0, NaN] }
        ])
      )
    }
    const mask = buildFooterMask(pages)
    expect(mask.size).toBe(0)
  })

  it('is pure: calling twice with the same input returns equal Maps', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 500 },
          { str: 'Running Footer', y: 40 }
        ])
      )
    }
    const a = buildFooterMask(pages)
    const b = buildFooterMask(pages)
    expect(a.size).toBe(b.size)
    for (const [page, setA] of a) {
      const setB = b.get(page)
      expect(setB).toBeDefined()
      expect([...setA].sort()).toEqual([...setB!].sort())
    }
  })

  it('exposes sensible defaults via DEFAULT_FOOTER_MASK_OPTIONS', () => {
    expect(DEFAULT_FOOTER_MASK_OPTIONS.minPages).toBe(8)
    expect(DEFAULT_FOOTER_MASK_OPTIONS.bottomBandPct).toBeCloseTo(0.25)
    expect(DEFAULT_FOOTER_MASK_OPTIONS.maxFooterLines).toBe(5)
    expect(DEFAULT_FOOTER_MASK_OPTIONS.maxCharsPerLine).toBe(250)
    expect(DEFAULT_FOOTER_MASK_OPTIONS.repetitionThreshold).toBeCloseTo(0.3)
    expect(DEFAULT_FOOTER_MASK_OPTIONS.yBinPct).toBeCloseTo(0.02)
  })
})
