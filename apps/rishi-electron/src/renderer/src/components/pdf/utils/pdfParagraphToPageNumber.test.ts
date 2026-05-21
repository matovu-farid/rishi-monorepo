import { describe, it, expect } from 'vitest'
import { pdfParagraphToPageNumber } from './pdfParagraphToPageNumber'

describe('pdfParagraphToPageNumber', () => {
  it('parses pdf-{page}-{idx} into the page number', () => {
    expect(pdfParagraphToPageNumber('pdf-1-0')).toBe(1)
    expect(pdfParagraphToPageNumber('pdf-42-7')).toBe(42)
  })

  it('returns null for empty input', () => {
    expect(pdfParagraphToPageNumber('')).toBeNull()
  })

  it('returns null for non-PDF paragraph ids', () => {
    expect(pdfParagraphToPageNumber('epubcfi(/6/4!/2)')).toBeNull()
    expect(pdfParagraphToPageNumber('azw3-1-2')).toBeNull()
    expect(pdfParagraphToPageNumber('42')).toBeNull()
  })

  it('returns null when page or idx is non-numeric', () => {
    expect(pdfParagraphToPageNumber('pdf-foo-7')).toBeNull()
    expect(pdfParagraphToPageNumber('pdf-7-foo')).toBeNull()
    expect(pdfParagraphToPageNumber('pdf--7')).toBeNull()
  })

  it('returns null when the page number is zero', () => {
    expect(pdfParagraphToPageNumber('pdf-0-0')).toBeNull()
  })

  it('returns null on missing segments', () => {
    expect(pdfParagraphToPageNumber('pdf-7')).toBeNull()
    expect(pdfParagraphToPageNumber('pdf-')).toBeNull()
  })
})
