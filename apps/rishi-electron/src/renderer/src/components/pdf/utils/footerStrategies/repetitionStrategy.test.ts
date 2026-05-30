import { describe, it, expect } from 'vitest'
import { repetitionStrategy } from './repetitionStrategy'
import {
  buildFooterMask,
  DEFAULT_FOOTER_MASK_OPTIONS,
  type PageScanInput
} from '../buildFooterMask'

const VIEWPORT_HEIGHT = 600

const makeItem = (it: {
  str: string
  y: number
  height?: number
  width?: number
  transform?: number[]
  hasEOL?: boolean
}): any => ({
  str: it.str,
  dir: 'ltr',
  width: it.width ?? Math.max(10, it.str.length * 5),
  height: it.height ?? 12,
  transform: it.transform ?? [12, 0, 0, 12, 0, it.y],
  fontName: 'g_d0_f1',
  hasEOL: it.hasEOL ?? true
})

const makePage = (
  pageNumber: number,
  items: { str: string; y: number }[]
): PageScanInput => ({
  pageNumber,
  content: { items: items.map(makeItem), styles: {} as any } as any,
  viewportHeight: VIEWPORT_HEIGHT
})

describe('repetitionStrategy', () => {
  it('flags items that appear at the same y-bin and text on >= 30% of pages', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 10; p++) {
      pages.push(
        makePage(p, [
          { str: 'BODY TEXT body text body text body text body text body text', y: 400 },
          { str: String(p), y: 30 }
        ])
      )
    }
    const mask = repetitionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    for (let p = 1; p <= 10; p++) {
      expect(mask.get(p)?.has(1)).toBe(true)
      expect(mask.get(p)?.has(0)).toBeFalsy()
    }
  })

  it('matches what the current buildFooterMask produces (parity)', () => {
    const pages: PageScanInput[] = []
    for (let p = 1; p <= 12; p++) {
      pages.push(
        makePage(p, [
          { str: 'Body content body content body content body content', y: 400 },
          { str: `Page ${p}`, y: 30 }
        ])
      )
    }
    const fromStrategy = repetitionStrategy(pages, DEFAULT_FOOTER_MASK_OPTIONS)
    const fromCurrent = buildFooterMask(pages)

    expect([...fromStrategy.keys()].sort()).toEqual([...fromCurrent.keys()].sort())
    for (const p of fromStrategy.keys()) {
      expect([...(fromStrategy.get(p) ?? [])].sort()).toEqual(
        [...(fromCurrent.get(p) ?? [])].sort()
      )
    }
  })
})
