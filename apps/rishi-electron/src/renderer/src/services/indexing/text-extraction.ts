import type * as PdfJs from 'pdfjs-dist'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import { pageDataToParagraphs } from '@/components/pdf/utils/getPageParagraphs'

// pdfjs-dist requires a worker. The renderer-side `pdf.tsx` already configures
// `pdfjs.GlobalWorkerOptions.workerSrc` for production. In Node test runs we
// fall back to the legacy build with `disableWorker: true` so the same module
// works in both environments.
async function loadPdfjs(): Promise<typeof PdfJs> {
  if (typeof window !== 'undefined' && (window as unknown as { electron?: unknown }).electron) {
    return import('pdfjs-dist')
  }
  const legacy = await import('pdfjs-dist/legacy/build/pdf.mjs')
  return legacy
}

export async function loadPdfDocument(bytes: Uint8Array): Promise<PDFDocumentProxy> {
  const pdfjs = await loadPdfjs()
  const isTest =
    typeof window === 'undefined' || !(window as unknown as { electron?: unknown }).electron

  // Clone the buffer because pdfjs transfers/detaches the underlying ArrayBuffer.
  const data = new Uint8Array(bytes)

  const task = pdfjs.getDocument({
    data,
    ...(isTest
      ? {
          disableWorker: true,
          isEvalSupported: false,
          useSystemFonts: false
        }
      : {})
  })
  return task.promise
}

export async function extractPageParagraphs(
  doc: PDFDocumentProxy,
  pageNumber: number
): Promise<string[]> {
  if (pageNumber < 1 || pageNumber > doc.numPages) return []

  const page = await doc.getPage(pageNumber)
  try {
    const content = await page.getTextContent()
    // Use the same positional paragraph algorithm the visible reader uses
    // (Y-coordinate gaps + hasEOL + 5-line floor + short-paragraph merge).
    // Indexer and reader chunking stay consistent — same paragraph the user
    // sees is the same chunk stored for RAG.
    return pageDataToParagraphs(pageNumber, content).map((p) => p.text.trim())
  } finally {
    page.cleanup()
  }
}
