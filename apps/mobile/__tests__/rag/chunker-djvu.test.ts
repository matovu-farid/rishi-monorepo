/**
 * DJVU chunker integration test.
 *
 * DJVU extraction runs inside a WebView using djvu.js (loaded from CDN), so
 * the chunker dispatches to an injectable DJVU extractor. We register a fake
 * extractor and assert chunks come back populated.
 */

jest.mock('expo-crypto', () => ({
  randomUUID: () => 'uuid-not-expected-here',
}))

jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn(),
  EncodingType: { Base64: 'base64' },
}))

import {
  getChunks,
  setDjvuExtractor,
  resetExtractors,
} from '@/lib/rag/chunker'

describe('chunker -> DJVU', () => {
  beforeEach(() => {
    resetExtractors()
  })

  it('invokes the registered DJVU extractor and produces chunks', async () => {
    const extractor = jest.fn(async (_filePath: string) => [
      { pageNumber: 1, paragraphs: ['DjVu page one text.'] },
      { pageNumber: 2, paragraphs: ['DjVu page two text.'] },
    ])
    setDjvuExtractor(extractor)

    const chunks = await getChunks('/fake/book.djvu', 'djvu', 'book-djvu-1')
    expect(extractor).toHaveBeenCalledWith('/fake/book.djvu')
    expect(chunks.length).toBeGreaterThan(0)
    for (const c of chunks) {
      expect(c.text.trim().length).toBeGreaterThan(0)
    }
  })

  it('returns empty when no DJVU extractor is registered', async () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    const chunks = await getChunks('/fake/book.djvu', 'djvu', 'book-djvu-none')
    expect(chunks).toEqual([])
    expect(warn).toHaveBeenCalled()
    warn.mockRestore()
  })

  it('produces stable IDs (same bookId + chunk text -> same id)', async () => {
    const pages = [
      { pageNumber: 1, paragraphs: ['Stable djvu chunk text one.'] },
      { pageNumber: 2, paragraphs: ['Stable djvu chunk text two.'] },
    ]
    setDjvuExtractor(async () => pages)
    const a = await getChunks('/fake/book.djvu', 'djvu', 'book-djvu-stable')

    resetExtractors()
    setDjvuExtractor(async () => pages)
    const b = await getChunks('/fake/book.djvu', 'djvu', 'book-djvu-stable')

    expect(a.map((c) => c.id)).toEqual(b.map((c) => c.id))
  })
})
