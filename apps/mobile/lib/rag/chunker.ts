import * as FileSystem from 'expo-file-system'
import {
  parseMobiTextParagraphs,
  parseMobiChapters,
} from '@rishi/shared/formats/mobi'
import { stringToNumberID } from '@rishi/shared/lib/stringToNumberID'
import type { TextChunk } from '@/types/conversation'

// ---------------------------------------------------------------------------
// Format-specific extractor registry
//
// PDF and DJVU text extraction on mobile both run inside a hidden WebView (no
// reliable in-process pdfjs / djvu.js on RN 0.81). Hosting those WebViews is
// a React/Native concern, so the chunker exposes an injectable port per
// format. The book-import flow registers a real extractor at app start; the
// jest tests register a fake.
//
// MOBI/AZW3 don't need this indirection — they're pure PalmDOC parsing and
// run synchronously via @rishi/shared/formats/mobi.
// ---------------------------------------------------------------------------

export interface ExtractedPage {
  pageNumber: number
  paragraphs: string[]
}

export type FormatExtractor = (filePath: string) => Promise<ExtractedPage[]>

let _pdfExtractor: FormatExtractor | null = null
let _djvuExtractor: FormatExtractor | null = null

export function setPdfExtractor(fn: FormatExtractor): void {
  _pdfExtractor = fn
}

export function setDjvuExtractor(fn: FormatExtractor): void {
  _djvuExtractor = fn
}

/**
 * Test hook: clear all registered extractors so jest tests start clean.
 */
export function resetExtractors(): void {
  _pdfExtractor = null
  _djvuExtractor = null
}

// ---------------------------------------------------------------------------
// Stable chunk IDs
//
// Same (bookId, chunkText) -> same id, regardless of platform or run. This
// matches the parity goal in .parity/GAP-ANALYSIS.md so chunks can be
// dedup'd across electron + mobile.
//
// We use stringToNumberID (also exported by @rishi/shared) because it's the
// already-shared deterministic hash function. We pair it with bookId and the
// chunk text so different books with identical text don't collide.
//
// Note: electron's PDF pipeline uses a different per-page formula
// (chunkId(pageNumber, bookId, index) in @rishi/shared/indexing/index-program).
// That formula needs a numeric bookId; mobile uses string bookIds (UUIDs).
// See .parity/BATCH-2A-NOTES.md for the deviation.
// ---------------------------------------------------------------------------

function chunkIdFor(bookId: string, chunkText: string): string {
  return stringToNumberID(`${bookId}|${chunkText}`).toString()
}

// ---------------------------------------------------------------------------
// EPUB extraction (unchanged behavior)
// ---------------------------------------------------------------------------

export async function extractEpubText(
  filePath: string
): Promise<Array<{ text: string; chapter: string | null }>> {
  const JSZip = (await import('jszip')).default
  const base64 = await FileSystem.readAsStringAsync(filePath, {
    encoding: FileSystem.EncodingType.Base64,
  })
  const zip = await JSZip.loadAsync(base64, { base64: true })

  const containerXml = await zip.file('META-INF/container.xml')?.async('text')
  if (!containerXml) {
    console.warn('[chunker] Missing META-INF/container.xml')
    return []
  }

  const rootfileMatch = containerXml.match(/<rootfile[^>]*full-path="([^"]+)"/)
  if (!rootfileMatch) {
    console.warn('[chunker] Could not find rootfile path in container.xml')
    return []
  }
  const opfPath = rootfileMatch[1]
  const opfDir = opfPath.includes('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : ''

  const opfXml = await zip.file(opfPath)?.async('text')
  if (!opfXml) {
    console.warn('[chunker] Could not read OPF file:', opfPath)
    return []
  }

  // Walk each <item> tag and extract id + href independently. The
  // earlier regex required `id` to appear BEFORE `href`, but Calibre /
  // Sigil emit items with arbitrary attribute order, leaving the
  // manifest map empty and yielding 0 chunks for valid books. (H3-05)
  const manifestItems = new Map<string, string>()
  const itemTagRegex = /<item\b[^>]*\/?>/gi
  let itemMatch: RegExpExecArray | null
  while ((itemMatch = itemTagRegex.exec(opfXml)) !== null) {
    const tag = itemMatch[0]
    const idAttr = tag.match(/\bid="([^"]+)"/)
    const hrefAttr = tag.match(/\bhref="([^"]+)"/)
    if (idAttr && hrefAttr) {
      manifestItems.set(idAttr[1], hrefAttr[1])
    }
  }

  const spineIdrefs: string[] = []
  const spineMatch = opfXml.match(/<spine[^>]*>([\s\S]*?)<\/spine>/)
  if (spineMatch) {
    const itemrefRegex = /<itemref\s+[^>]*idref="([^"]+)"/g
    let refMatch: RegExpExecArray | null
    while ((refMatch = itemrefRegex.exec(spineMatch[1])) !== null) {
      spineIdrefs.push(refMatch[1])
    }
  }

  const sections: Array<{ text: string; chapter: string | null }> = []

  for (const idref of spineIdrefs) {
    const href = manifestItems.get(idref)
    if (!href) {
      console.warn('[chunker] Spine idref not found in manifest:', idref)
      continue
    }

    // Some publishers (Sigil, Smashwords) emit hrefs starting with `/`
    // meaning "root of the zip". Without this branch the join becomes
    // `OEBPS//ch1.xhtml` and the file lookup fails, returning 0 chunks
    // for an otherwise valid EPUB. Mirrors epub-cover.ts behavior.
    const joinedPath = href.startsWith('/') ? href.slice(1) : opfDir + href
    // KF8 / Sigil templates can also produce ../ segments that point at
    // a sibling directory of the OPF. JSZip doesn't normalize paths, so
    // we collapse `.` and `..` segments before the lookup. (H3-07)
    const fullPath = normalizeZipPath(joinedPath)
    try {
      const xhtml =
        (await zip.file(fullPath)?.async('text')) ??
        (await zip.file(joinedPath)?.async('text'))
      if (!xhtml) {
        console.warn('[chunker] Could not read spine item:', fullPath)
        continue
      }

      const headingMatch = xhtml.match(/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/)
      const chapter = headingMatch
        ? headingMatch[1].replace(/<[^>]*>/g, '').trim() || idref
        : null

      const text = xhtml
        .replace(/<[^>]*>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim()

      if (text.length > 0) {
        sections.push({ text, chapter })
      }
    } catch (err) {
      console.warn('[chunker] Error processing spine item:', fullPath, err)
    }
  }

  return sections
}

// ---------------------------------------------------------------------------
// chunkText: sentence-aware splitter (unchanged signature)
//
// Returns chunks with empty id+bookId — the higher-level chunkSections()
// stamps the deterministic IDs. The existing chunker.test.ts asserts the
// chunkText contract directly, so we keep its public behavior unchanged.
// ---------------------------------------------------------------------------

export function chunkText(
  sections: Array<{ text: string; chapter: string | null }>,
  maxChunkSize: number = 500,
  overlap: number = 50
): TextChunk[] {
  const chunks: TextChunk[] = []
  let chunkIndex = 0

  for (const section of sections) {
    const { text, chapter } = section
    if (!text || text.trim().length === 0) continue

    const sentences = text.split(/(?<=[.!?])\s+/)
    let currentChunk = ''

    const pushChunk = (chunkContent: string) => {
      const trimmed = chunkContent.trim()
      if (trimmed.length === 0) return
      chunks.push({
        id: '',
        bookId: '',
        chunkIndex: chunkIndex++,
        text: trimmed,
        chapter,
        createdAt: Date.now(),
      })
    }

    for (const sentence of sentences) {
      if (currentChunk.length + sentence.length + 1 > maxChunkSize && currentChunk.length > 0) {
        pushChunk(currentChunk)
        if (overlap > 0) {
          const overlapText = currentChunk.slice(-overlap)
          currentChunk = overlapText + ' ' + sentence
        } else {
          currentChunk = sentence
        }
      } else {
        currentChunk = currentChunk ? currentChunk + ' ' + sentence : sentence
      }
    }

    pushChunk(currentChunk)
  }

  return chunks
}

/**
 * Like chunkText() but stamps deterministic IDs derived from (bookId, text)
 * so the same chunk re-imports to the same row.
 */
function chunkSections(
  sections: Array<{ text: string; chapter: string | null }>,
  bookId: string,
  maxChunkSize: number = 500,
  overlap: number = 50
): TextChunk[] {
  const raw = chunkText(sections, maxChunkSize, overlap)
  return raw.map((c) => ({
    ...c,
    id: chunkIdFor(bookId, c.text),
    bookId,
  }))
}

// ---------------------------------------------------------------------------
// MOBI / AZW3 extraction via @rishi/shared/formats/mobi
//
// AZW3 uses the same PalmDOC + EXTH layout as MOBI in practice. We call the
// shared parser, then flatten each chapter's paragraphs into a single section
// so the sentence-aware chunker can split it normally.
// ---------------------------------------------------------------------------

async function extractMobiSections(
  filePath: string
): Promise<Array<{ text: string; chapter: string | null }>> {
  const base64 = await FileSystem.readAsStringAsync(filePath, {
    encoding: FileSystem.EncodingType.Base64,
  })
  const bytes = base64ToUint8Array(base64)

  const chaptersOfParagraphs = parseMobiTextParagraphs(bytes)
  // Fallback when the paragraph-splitter yielded nothing (rare): emit the
  // raw stripped HTML so chunking still produces output.
  if (chaptersOfParagraphs.every((chapter) => chapter.length === 0)) {
    const htmlChapters = parseMobiChapters(bytes)
    if (htmlChapters.length === 0) return []
    return htmlChapters
      .map((html, i) => ({
        text: html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim(),
        chapter: `Chapter ${i + 1}`,
      }))
      .filter((s) => s.text.length > 0)
  }

  return chaptersOfParagraphs
    .map((paragraphs, i) => ({
      text: paragraphs.join('\n'),
      chapter: `Chapter ${i + 1}`,
    }))
    .filter((s) => s.text.length > 0)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Collapse `.` and `..` segments in a zip-relative path so JSZip can
 * resolve hrefs like `OEBPS/../Text/ch1.xhtml`. (H3-07)
 */
function normalizeZipPath(path: string): string {
  const segments = path.split('/')
  const out: string[] = []
  for (const seg of segments) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') {
      out.pop()
      continue
    }
    out.push(seg)
  }
  return out.join('/')
}

function base64ToUint8Array(base64: string): Uint8Array {
  // Both RN and Node 18+ have atob in globalThis; fall back to node:buffer
  // for older environments just to be safe.
  if (typeof atob === 'function') {
    const binary = atob(base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  }
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const nodeBuffer = require('node:buffer') as typeof import('node:buffer')
  return new Uint8Array(nodeBuffer.Buffer.from(base64, 'base64'))
}

/**
 * Convert per-page paragraph output (PDF / DJVU) into sections the
 * sentence-aware chunker expects. One paragraph -> one section so cross-page
 * sentence merging doesn't happen accidentally.
 */
function pagesToSections(
  pages: ExtractedPage[]
): Array<{ text: string; chapter: string | null }> {
  const sections: Array<{ text: string; chapter: string | null }> = []
  for (const page of pages) {
    for (const paragraph of page.paragraphs) {
      const trimmed = paragraph.trim()
      if (trimmed.length === 0) continue
      sections.push({ text: trimmed, chapter: `Page ${page.pageNumber}` })
    }
  }
  return sections
}

// ---------------------------------------------------------------------------
// Format dispatch — the single entrypoint the pipeline calls
// ---------------------------------------------------------------------------

export async function getChunks(
  filePath: string,
  format: string,
  bookId?: string
): Promise<TextChunk[]> {
  const id = bookId ?? ''
  const normalized = format.toLowerCase()

  if (normalized === 'epub') {
    const sections = await extractEpubText(filePath)
    return chunkSections(sections, id)
  }

  if (normalized === 'pdf') {
    if (!_pdfExtractor) {
      console.warn(
        '[chunker] PDF extractor not registered — call setPdfExtractor() at app start'
      )
      return []
    }
    const pages = await _pdfExtractor(filePath)
    return chunkSections(pagesToSections(pages), id)
  }

  if (normalized === 'mobi' || normalized === 'azw3') {
    const sections = await extractMobiSections(filePath)
    return chunkSections(sections, id)
  }

  if (normalized === 'djvu') {
    if (!_djvuExtractor) {
      console.warn(
        '[chunker] DJVU extractor not registered — call setDjvuExtractor() at app start'
      )
      return []
    }
    const pages = await _djvuExtractor(filePath)
    return chunkSections(pagesToSections(pages), id)
  }

  console.warn(`[chunker] Unknown format: ${format}`)
  return []
}
