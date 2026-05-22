import { describe, it, expect } from 'vitest'
import { azw3ParagraphToLocation } from './paragraphToLocation'

describe('azw3ParagraphToLocation', () => {
  it('extracts the chapter from a well-formed paragraph id', () => {
    expect(azw3ParagraphToLocation('azw3-0-0')).toEqual({ chapter: 0, page: 0 })
    expect(azw3ParagraphToLocation('azw3-3-12')).toEqual({ chapter: 3, page: 0 })
  })

  it('returns null on empty input', () => {
    expect(azw3ParagraphToLocation('')).toBeNull()
  })

  it('returns null for non-AZW3 paragraph ids', () => {
    expect(azw3ParagraphToLocation('pdf-3-2')).toBeNull()
    expect(azw3ParagraphToLocation('epubcfi(/6/4)')).toBeNull()
    expect(azw3ParagraphToLocation('1')).toBeNull()
  })

  it('returns null on missing or non-numeric segments', () => {
    expect(azw3ParagraphToLocation('azw3-foo-1')).toBeNull()
    expect(azw3ParagraphToLocation('azw3-1-foo')).toBeNull()
    expect(azw3ParagraphToLocation('azw3-1')).toBeNull()
  })
})
