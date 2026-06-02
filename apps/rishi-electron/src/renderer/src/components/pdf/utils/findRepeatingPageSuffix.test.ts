import { describe, it, expect } from 'vitest'
import { findRepeatingPageSuffix } from './findRepeatingPageSuffix'
import type { PageScanInput } from './buildFooterMask'

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------
//
// pdfjs-dist TextItem.transform is a 6-element matrix [a, b, c, d, e, f] where
// f (index 5) is the y-position in PDF user space (origin = bottom-left). We
// hand-roll just the fields the raw paragraph assembler reads — str, height,
// transform[5], hasEOL. The assembler splits paragraphs when consecutive items
// are vertically separated by > 1.5 * height AND have hasEOL. With height=12
// that threshold is 18 user-space units, so we space lines >= 30 apart to
// guarantee separate paragraphs.

const VIEWPORT_HEIGHT = 800

interface FixtureItem {
  str: string
  y: number
  height?: number
  hasEOL?: boolean
}

const makeItem = (it: FixtureItem): any => ({
  str: it.str,
  dir: 'ltr',
  width: Math.max(10, it.str.length * 5),
  height: it.height ?? 12,
  transform: [12, 0, 0, 12, 0, it.y],
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

describe('findRepeatingPageSuffix', () => {
  it('returns empty Map when pages.length < minPages', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 5; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body of page ' + p, y: 700 },
          { str: 'Copyright Foo Bar', y: 40 } // repeats, but too few pages
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    expect(mask.size).toBe(0)
  })

  it('masks a single repeating bottom paragraph across pages', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: `Distinct body topic ${String.fromCharCode(64 + p)} for page ${p}`, y: 700 },
          { str: 'Copyright Foo Bar', y: 40 }
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    expect(mask.size).toBe(10)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      expect(set, `page ${p} should have masked indices`).toBeDefined()
      // index 1 is the footer item; index 0 is body content
      expect(set!.has(1)).toBe(true)
      expect(set!.has(0)).toBe(false)
    }
  })

  it('masks a small-font repeating footer (footnote-style item) across pages', () => {
    // The positional footnote detector (detectFootnoteItems) flags small-font
    // items below the body. The SHARED raw assembler must NOT drop them on the
    // footer-detection path, or the repetition mask is starved and never
    // builds. Regression guard for the reading-order/footnote work.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          {
            str: `Distinct body topic ${String.fromCharCode(64 + p)} for page ${p}`,
            y: 700,
            height: 12
          },
          { str: 'Copyright Foo Bar', y: 40, height: 8 }
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    expect(mask.size).toBe(10)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      expect(set, `page ${p} should have masked indices`).toBeDefined()
      expect(set!.has(1)).toBe(true)
      expect(set!.has(0)).toBe(false)
    }
  })

  it('masks a footer that spans multiple paragraphs', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: `Distinct body topic ${String.fromCharCode(64 + p)} for page ${p}`, y: 700 },
          // Three distinct paragraphs of a copyright block. Spaced > 30 apart
          // so each is its own paragraph in the assembler.
          { str: 'Copyright 2024 Foo Corp', y: 130 },
          { str: 'All rights reserved', y: 90 },
          { str: 'See foo.com/terms', y: 50 }
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    expect(mask.size).toBe(10)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      expect(set, `page ${p} should have masked indices`).toBeDefined()
      // Items 1, 2, 3 all belong to the three repeating footer paragraphs.
      expect(set!.has(1)).toBe(true)
      expect(set!.has(2)).toBe(true)
      expect(set!.has(3)).toBe(true)
      expect(set!.has(0)).toBe(false)
    }
  })

  it('does NOT mask varied per-page body paragraphs', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: `Distinct body topic ${String.fromCharCode(64 + p)} for page ${p}`, y: 700 },
          // Unique conclusion text per page — no repetition signal.
          {
            str: `Page ${p} body conclusion text varies ${String.fromCharCode(64 + p)}`,
            y: 40
          }
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set) expect(set.has(1)).toBe(false)
    }
  })

  it('tolerates digit variation in repeating page-number footers', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: `Distinct body topic ${String.fromCharCode(64 + p)} for page ${p}`, y: 700 },
          { str: 'Page ' + p, y: 40 } // distinct strings, equivalent after normalization
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    expect(mask.size).toBe(10)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      expect(set, `page ${p} should have masked indices`).toBeDefined()
      expect(set!.has(1)).toBe(true)
    }
  })

  it('does not mask body text at the bottom that fails the repetition threshold', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      // Only pages 1 and 2 share the same bottom paragraph (2/10 = 20% < 30%).
      // Other pages use the random alphabetic suffix to ensure normalization
      // doesn't collapse them onto each other (digit-replace would).
      const uniqueSuffix = `closing remark ${String.fromCharCode(64 + p)}${String.fromCharCode(96 + p)} subject`
      const bottomText = p <= 2 ? 'Shared closing remark only on two pages' : uniqueSuffix
      pages.push(
        makePage(p, [
          { str: `Distinct body topic ${String.fromCharCode(64 + p)} for page ${p}`, y: 700 },
          { str: bottomText, y: 40 }
        ])
      )
    }
    const mask = findRepeatingPageSuffix(pages)
    for (let p = 1; p <= 10; p++) {
      const set = mask.get(p)
      if (set) expect(set.has(1)).toBe(false)
    }
  })
})
