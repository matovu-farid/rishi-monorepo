import { describe, it, expect } from 'vitest'
import { parseLocation, formatLocation, measurePageCount, computePageStep } from './pagination'

describe('parseLocation', () => {
  it('parses the new "<chapter>:<page>" format', () => {
    expect(parseLocation('0:0')).toEqual({ chapter: 0, page: 0 })
    expect(parseLocation('5:3')).toEqual({ chapter: 5, page: 3 })
  })

  it('parses the legacy bare-integer format as page 0 of that chapter', () => {
    expect(parseLocation('7')).toEqual({ chapter: 7, page: 0 })
  })

  it('falls back to {0, 0} for empty/null/undefined input', () => {
    expect(parseLocation('')).toEqual({ chapter: 0, page: 0 })
    expect(parseLocation(null)).toEqual({ chapter: 0, page: 0 })
    expect(parseLocation(undefined)).toEqual({ chapter: 0, page: 0 })
  })

  it('falls back to {0, 0} for non-numeric inputs', () => {
    expect(parseLocation('abc:def')).toEqual({ chapter: 0, page: 0 })
  })

  it('clamps negative values to 0', () => {
    expect(parseLocation('-3:-1')).toEqual({ chapter: 0, page: 0 })
  })

  it('floors fractional indices', () => {
    expect(parseLocation('2.9:4.7')).toEqual({ chapter: 2, page: 4 })
  })
})

describe('formatLocation', () => {
  it('serializes to "<chapter>:<page>"', () => {
    expect(formatLocation(0, 0)).toBe('0:0')
    expect(formatLocation(12, 5)).toBe('12:5')
  })

  it('roundtrips through parseLocation', () => {
    expect(parseLocation(formatLocation(4, 9))).toEqual({ chapter: 4, page: 9 })
  })
})

describe('computePageStep', () => {
  it('returns clientWidth + columnGap', () => {
    expect(computePageStep(1024, 48)).toBe(1072)
    expect(computePageStep(800, 0)).toBe(800)
  })

  it('floors at 1 to avoid divide-by-zero downstream', () => {
    expect(computePageStep(0, 0)).toBe(1)
    expect(computePageStep(-10, 0)).toBe(1)
  })
})

describe('measurePageCount', () => {
  it('returns 1 when clientWidth is zero or negative', () => {
    expect(measurePageCount(1000, 0, 0)).toBe(1)
    expect(measurePageCount(1000, -100, 0)).toBe(1)
  })

  it('returns 1 for a chapter that fits in a single page', () => {
    expect(measurePageCount(800, 1024, 48)).toBe(1)
    expect(measurePageCount(0, 1024, 48)).toBe(1)
  })

  it('returns 1 when scrollWidth equals clientWidth exactly (W = W, G)', () => {
    expect(measurePageCount(1024, 1024, 48)).toBe(1)
  })

  it('returns 2 when scrollWidth = clientWidth + pageStep (2W + G)', () => {
    // pageStep = W + G; scrollWidth = clientWidth + pageStep = 2W + G
    expect(measurePageCount(2 * 1024 + 48, 1024, 48)).toBe(2)
  })

  it('returns 3 when scrollWidth = 3W + 2G', () => {
    // scrollWidth - clientWidth = 2W + 2G = 2 * pageStep
    expect(measurePageCount(3 * 1024 + 2 * 48, 1024, 48)).toBe(3)
  })

  it('works with zero column gap (degenerates to viewport-snapped)', () => {
    expect(measurePageCount(2048, 1024, 0)).toBe(2)
    expect(measurePageCount(4096, 1024, 0)).toBe(4)
  })

  it('does not over-count when content overflows by a single pixel', () => {
    // With clientWidth=1024 and gap=48, pageStep=1072.
    // scrollWidth=1025 → (1025 - 1024) / 1072 = 0 → 1 page.
    expect(measurePageCount(1025, 1024, 48)).toBe(1)
  })
})
