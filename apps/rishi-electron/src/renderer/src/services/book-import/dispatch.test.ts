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
  azw3Returns?: BookDataParsed
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
    getAzw3Data: vi.fn(async (path: string) => {
      calls.push({ method: 'getAzw3Data', path })
      return opts?.azw3Returns ?? { ...sampleParsed, kind: 'azw3' }
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

describe('dispatchFormatExtraction — extension routing', () => {
  it('routes .pdf to formats.getPdfData', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.pdf')
    expect(result.format).toBe('pdf')
    expect(calls).toEqual([{ method: 'getPdfData', path: '/tmp/book.pdf' }])
  })

  it('routes .mobi to formats.getMobiData', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.mobi')
    expect(result.format).toBe('mobi')
    expect(calls).toEqual([{ method: 'getMobiData', path: '/tmp/book.mobi' }])
  })

  it('routes .azw3 to formats.getAzw3Data and returns kind=azw3', async () => {
    const { formats, calls } = makeFormats()
    const result = await dispatchFormatExtraction(formats, '/tmp/book.azw3')
    expect(result.format).toBe('azw3')
    expect(result.data.kind).toBe('azw3')
    expect(calls).toEqual([{ method: 'getAzw3Data', path: '/tmp/book.azw3' }])
  })

  it('throws UnsupportedFormatError for unknown extensions', async () => {
    const { formats, calls } = makeFormats()
    await expect(dispatchFormatExtraction(formats, '/tmp/notes.txt')).rejects.toBeInstanceOf(
      UnsupportedFormatError
    )
    expect(calls).toEqual([])
  })

  it('is case-insensitive on the extension', async () => {
    const { formats, calls } = makeFormats()
    await dispatchFormatExtraction(formats, '/tmp/BOOK.EPUB')
    expect(calls).toEqual([{ method: 'getBookData', path: '/tmp/BOOK.EPUB' }])
  })
})
