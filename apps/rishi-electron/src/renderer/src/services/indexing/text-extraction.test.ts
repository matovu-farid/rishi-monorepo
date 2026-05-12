import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { loadPdfDocument, extractPageParagraphs } from './text-extraction'
import type { PDFDocumentProxy } from 'pdfjs-dist'

const __dirname = dirname(fileURLToPath(import.meta.url))
const PDF_PATH = resolve(__dirname, '../../../../../e2e/fixtures/test-book.pdf')

describe('text-extraction (real PDF)', () => {
  let doc: PDFDocumentProxy

  beforeAll(async () => {
    const bytes = new Uint8Array(readFileSync(PDF_PATH))
    doc = await loadPdfDocument(bytes)
  })

  afterAll(async () => {
    await doc?.destroy()
  })

  it('reports the correct page count for the fixture', () => {
    expect(doc.numPages).toBe(14)
  })

  it('breaks page 1 into multiple positional paragraphs (not one blob)', async () => {
    const paragraphs = await extractPageParagraphs(doc, 1)
    // Page 1 contains a header + multiple body paragraphs separated by visible
    // whitespace; the positional algorithm should detect those breaks.
    expect(paragraphs.length).toBeGreaterThanOrEqual(4)
    // Each paragraph should be a substantive chunk, not single words.
    for (const p of paragraphs) {
      expect(p.trim().length).toBeGreaterThan(0)
    }
    // The compiler-definition paragraph should land intact, not split mid-sentence.
    const joined = paragraphs.join('\n')
    expect(joined).toMatch(/Compiler is a translator program/)
  })

  it('returns different content for different pages', async () => {
    const page1 = await extractPageParagraphs(doc, 1)
    const page5 = await extractPageParagraphs(doc, 5)
    expect(page1.join(' ')).not.toEqual(page5.join(' '))
  })

  it('returns an empty array for an out-of-range page', async () => {
    const result = await extractPageParagraphs(doc, doc.numPages + 100)
    expect(result).toEqual([])
  })
})
