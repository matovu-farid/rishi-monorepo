import { describe, it, expect } from 'vitest'
import { getParagraphThreshold } from './getParagraphThreshold'

describe('getParagraphThreshold', () => {
  it('returns 1.5x the item height when height is available', () => {
    const item = {
      str: 'test',
      dir: 'ltr',
      width: 100,
      height: 14,
      transform: [14, 0, 0, 14, 0, 700],
      fontName: 'g_d0_f1',
      hasEOL: false
    } as any

    expect(getParagraphThreshold(item)).toBe(21)
  })

  it('returns 12 as fallback when height is 0', () => {
    const item = {
      str: 'test',
      dir: 'ltr',
      width: 100,
      height: 0,
      transform: [14, 0, 0, 14, 0, 700],
      fontName: 'g_d0_f1',
      hasEOL: false
    } as any

    expect(getParagraphThreshold(item)).toBe(12)
  })

  it('returns 12 as fallback when height is not a number', () => {
    const item = {
      str: 'test',
      dir: 'ltr',
      width: 100,
      transform: [14, 0, 0, 14, 0, 700],
      fontName: 'g_d0_f1',
      hasEOL: false
    } as any

    expect(getParagraphThreshold(item)).toBe(12)
  })

  it('handles various height values correctly', () => {
    const makeItem = (height: number) =>
      ({
        str: 'x',
        dir: 'ltr',
        width: 50,
        height,
        transform: [10, 0, 0, 10, 0, 500],
        fontName: 'f1',
        hasEOL: false
      }) as any

    expect(getParagraphThreshold(makeItem(10))).toBe(15)
    expect(getParagraphThreshold(makeItem(20))).toBe(30)
    expect(getParagraphThreshold(makeItem(8))).toBe(12)
  })
})
