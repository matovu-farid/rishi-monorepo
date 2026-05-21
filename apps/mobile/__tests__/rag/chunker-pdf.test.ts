/**
 * PDF chunker integration test.
 *
 * The mobile chunker dispatches PDF extraction to an injectable extractor so
 * the heavy WebView-based pdfjs path doesn't run under jest. We register a
 * fake extractor that returns deterministic per-page paragraphs and assert
 * the chunker produces non-empty chunks with stable IDs (Batch 2A G04).
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
  setPdfExtractor,
  resetExtractors,
} from '@/lib/rag/chunker'

describe('chunker -> PDF', () => {
  beforeEach(() => {
    resetExtractors()
  })

  it('produces non-empty chunks when the PDF extractor returns paragraphs', async () => {
    setPdfExtractor(async (_filePath: string) => [
      { pageNumber: 1, paragraphs: ['hello world.', 'second paragraph on page one.'] },
      { pageNumber: 2, paragraphs: ['page two text.'] },
    ])

    const chunks = await getChunks('/fake/path/to.pdf', 'pdf', 'book-abc')
    expect(chunks.length).toBeGreaterThan(0)
    for (const c of chunks) {
      expect(c.text.trim().length).toBeGreaterThan(0)
    }
  })

  it('produces stable IDs (same bookId + chunkText -> same id)', async () => {
    setPdfExtractor(async () => [
      { pageNumber: 1, paragraphs: ['hello world.', 'second paragraph on page one.'] },
    ])

    const first = await getChunks('/fake.pdf', 'pdf', 'book-stable')

    // Reset extractor and run again with same input
    resetExtractors()
    setPdfExtractor(async () => [
      { pageNumber: 1, paragraphs: ['hello world.', 'second paragraph on page one.'] },
    ])
    const second = await getChunks('/fake.pdf', 'pdf', 'book-stable')

    expect(first.map((c) => c.id)).toEqual(second.map((c) => c.id))
  })

  it('different bookIds yield different chunk IDs even for the same text', async () => {
    setPdfExtractor(async () => [
      { pageNumber: 1, paragraphs: ['identical text.'] },
    ])
    const a = await getChunks('/fake.pdf', 'pdf', 'book-A')

    resetExtractors()
    setPdfExtractor(async () => [
      { pageNumber: 1, paragraphs: ['identical text.'] },
    ])
    const b = await getChunks('/fake.pdf', 'pdf', 'book-B')

    expect(a[0].id).not.toEqual(b[0].id)
  })

  it('returns empty array when extractor returns no pages', async () => {
    setPdfExtractor(async () => [])
    const chunks = await getChunks('/fake.pdf', 'pdf', 'book-empty')
    expect(chunks).toEqual([])
  })

  it('warns and returns empty when no PDF extractor is registered', async () => {
    // resetExtractors already unregistered any prior extractor
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {})
    const chunks = await getChunks('/fake.pdf', 'pdf', 'book-no-extractor')
    expect(chunks).toEqual([])
    expect(warn).toHaveBeenCalled()
    warn.mockRestore()
  })
})
