/**
 * Per-format reader route resolution — defect P1-A.
 *
 * The chat "Source" tap was routing to `/reader/${bookId}` for every
 * format, which lands on the EPUB reader and errors out on PDF / MOBI /
 * DJVU files. The Library tab already had this branch inline; we
 * extract it into a pure helper so both call sites (Library + Chat)
 * agree.
 */
import { resolveReaderRouteForBook } from '@/lib/reader-routes'
import type { Book } from '@/types/book'

function bookFromFormat(format: Book['format']): Book {
  return {
    id: 'book-1',
    title: 't',
    author: 'a',
    coverPath: null,
    filePath: '/tmp/x',
    format,
    currentCfi: null,
    currentPage: null,
    lastProgressPercent: null,
    createdAt: 0,
  }
}

describe('resolveReaderRouteForBook (P1-A)', () => {
  it('routes EPUB to /reader/<id>', () => {
    expect(resolveReaderRouteForBook(bookFromFormat('epub'))).toBe('/reader/book-1')
  })
  it('routes PDF to /reader/pdf/<id>', () => {
    expect(resolveReaderRouteForBook(bookFromFormat('pdf'))).toBe('/reader/pdf/book-1')
  })
  it('routes MOBI to /reader/mobi/<id>', () => {
    expect(resolveReaderRouteForBook(bookFromFormat('mobi'))).toBe('/reader/mobi/book-1')
  })
  it('routes AZW3 to the MOBI reader (shared parser)', () => {
    // azw3 files run through the same mobi reader on mobile (the parser
    // is shared and R2 stores them under the same key).
    expect(resolveReaderRouteForBook(bookFromFormat('azw3'))).toBe('/reader/mobi/book-1')
  })
  it('routes DJVU to /reader/djvu/<id>', () => {
    expect(resolveReaderRouteForBook(bookFromFormat('djvu'))).toBe('/reader/djvu/book-1')
  })
})
