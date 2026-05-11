import { describe, it, expect, vi } from 'vitest'
import type { FormatsIpc, BookDataParsed } from './types'
import { dispatchFormatExtraction, UnsupportedFormatError } from './dispatch'

const sampleParsed: BookDataParsed = {
  kind: 'epub',
  cover: [],
  title: 'Sample',
  author: 'Author',
  publisher: 'Pub',
  coverKind: 'image/png'
}

export function makeFormats(opts?: {
  epubReturns?: BookDataParsed
  pdfReturns?: BookDataParsed
  mobiReturns?: BookDataParsed
  djvuReturns?: BookDataParsed
}): { formats: FormatsIpc; calls: Array<{ method: keyof FormatsIpc; path: string }> } {
  const calls: Array<{ method: keyof FormatsIpc; path: string }> = []
  const formats: FormatsIpc = {
    getBookData: vi.fn(async (path: string) => {
      calls.push({ method: 'getBookData', path })
      return opts?.epubReturns ?? sampleParsed
    }),
    getPdfData: vi.fn(async (path: string) => {
      calls.push({ method: 'getPdfData', path })
      return opts?.pdfReturns ?? { ...sampleParsed, kind: 'pdf' }
    }),
    getMobiData: vi.fn(async (path: string) => {
      calls.push({ method: 'getMobiData', path })
      return opts?.mobiReturns ?? { ...sampleParsed, kind: 'mobi' }
    }),
    getDjvuData: vi.fn(async (path: string) => {
      calls.push({ method: 'getDjvuData', path })
      return opts?.djvuReturns ?? { ...sampleParsed, kind: 'djvu' }
    })
  }
  return { formats, calls }
}

describe('dispatchFormatExtraction', () => {
  it('routes .epub to formats.getBookData and returns the parsed data + format', async () => {
    const { formats, calls } = makeFormats()

    const result = await dispatchFormatExtraction(formats, '/userData/book.epub')

    expect(result.format).toBe('epub')
    expect(result.data.kind).toBe('epub')
    expect(calls).toEqual([{ method: 'getBookData', path: '/userData/book.epub' }])
  })
})
