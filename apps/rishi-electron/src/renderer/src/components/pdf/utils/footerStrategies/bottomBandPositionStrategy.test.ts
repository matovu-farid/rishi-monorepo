import { describe, it, expect } from 'vitest'
import { bottomBandPositionStrategy } from './bottomBandPositionStrategy'
import { DEFAULT_FOOTER_MASK_OPTIONS, type PageScanInput } from '../buildFooterMask'

const VIEWPORT_HEIGHT = 600

const makeItem = (it: { str: string; y: number; hasEOL?: boolean }): any => ({
  str: it.str,
  dir: 'ltr',
  width: Math.max(10, it.str.length * 5),
  height: 12,
  transform: [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: it.hasEOL ?? true
})

const makePage = (pageNumber: number, items: { str: string; y: number }[]): PageScanInput => ({
  pageNumber,
  content: { items: items.map(makeItem), styles: {} as any } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

describe('bottomBandPositionStrategy', () => {
  it('flags every item at a y-bin that has ANY text on >= 30% of pages', () => {
    // 10 pages. y=30 always has SOME item (varying text per chapter), y=400 is body.
    const pages: PageScanInput[] = []
    const chapterTitles = [
      'Chapter 1',
      'Chapter 1',
      'Chapter 1',
      'Chapter 2',
      'Chapter 2',
      'Chapter 2',
      'Chapter 3',
      'Chapter 3',
      'Chapter 3',
      'Chapter 3'
    ]
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'BODY body body body body body body body body body body', y: 400 },
          { str: String(p), y: 30 }, // page number
          { str: chapterTitles[p - 1], y: 30 } // chapter title at same y-bin
        ])
      )
    }
    const mask = bottomBandPositionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    // For every page, items 1 and 2 (page number + chapter title) should be flagged.
    // Item 0 (body) should NOT be.
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.has(1)).toBe(true)
      expect(mask.get(p)?.has(2)).toBe(true)
      expect(mask.get(p)?.has(0)).toBeFalsy()
    }
  })

  it('does not flag anything when the y-bin appears on < 30% of pages', () => {
    // 10 pages. Only pages 1-2 (20%) have anything in the bottom band.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      const items = [{ str: 'body body body body body body body body body', y: 400 }]
      if (p <= 2) items.push({ str: 'one-off note', y: 30 })
      pages.push(makePage(p, items))
    }
    const mask = bottomBandPositionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.size ?? 0).toBe(0)
    }
  })

  it('ignores items outside the bottom band', () => {
    // 10 pages with a heading at y=500 (above bottom 25% band of 600px viewport,
    // i.e., band starts at y=150 and below). Even though heading repeats, it
    // should not be flagged.
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(makePage(p, [{ str: 'Heading', y: 500 }]))
    }
    const mask = bottomBandPositionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.size ?? 0).toBe(0)
    }
  })
})
