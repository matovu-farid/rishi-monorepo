// Pins the PDF book.location string parser. The format is "page:offset"
// (current) and bare "page" (legacy). Existing book rows persisted under the
// legacy format must still restore to the top of their saved page, and a
// roundtrip of the current format must preserve both axes.
import { describe, it, expect } from 'vitest'
import { parsePdfLocation, formatPdfLocation } from '../pdfLocation'

describe('parsePdfLocation', () => {
  it('parses the current "page:offset" format', () => {
    expect(parsePdfLocation('5:120')).toEqual({ page: 5, offset: 120 })
  })

  it('parses the legacy bare-page format with offset=0', () => {
    expect(parsePdfLocation('7')).toEqual({ page: 7, offset: 0 })
  })

  it('returns the zero-location for null/undefined/empty', () => {
    expect(parsePdfLocation(null)).toEqual({ page: 0, offset: 0 })
    expect(parsePdfLocation(undefined)).toEqual({ page: 0, offset: 0 })
    expect(parsePdfLocation('')).toEqual({ page: 0, offset: 0 })
  })

  it('clamps non-finite/negative components to zero rather than NaN', () => {
    expect(parsePdfLocation('garbage')).toEqual({ page: 0, offset: 0 })
    expect(parsePdfLocation('5:-30')).toEqual({ page: 5, offset: 0 })
    expect(parsePdfLocation('-2:50')).toEqual({ page: 0, offset: 50 })
  })
})

describe('formatPdfLocation', () => {
  it('roundtrips a current-format location losslessly', () => {
    const loc = { page: 12, offset: 340 }
    expect(parsePdfLocation(formatPdfLocation(loc))).toEqual(loc)
  })

  it('rounds and clamps the offset', () => {
    expect(formatPdfLocation({ page: 3, offset: 12.6 })).toBe('3:13')
    expect(formatPdfLocation({ page: 3, offset: -1 })).toBe('3:0')
  })
})
