import * as FileSystem from 'expo-file-system'
import { randomUUID } from 'expo-crypto'
import type { TextChunk } from '@/types/conversation'

/**
 * Extract text content from an EPUB file.
 * Reads the EPUB (ZIP) as base64, parses the OPF spine, and returns
 * an array of { text, chapter } sections in reading order.
 */
export async function extractEpubText(
  filePath: string
): Promise<Array<{ text: string; chapter: string | null }>> {
  const JSZip = (await import('jszip')).default
  const base64 = await FileSystem.readAsStringAsync(filePath, {
    encoding: FileSystem.EncodingType.Base64,
  })
  const zip = await JSZip.loadAsync(base64, { base64: true })

  // Parse container.xml to find the rootfile path
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

  // Parse OPF file
  const opfXml = await zip.file(opfPath)?.async('text')
  if (!opfXml) {
    console.warn('[chunker] Could not read OPF file:', opfPath)
    return []
  }

  // Extract manifest items: map id -> href
  const manifestItems = new Map<string, string>()
  const itemRegex = /<item\s+[^>]*id="([^"]+)"[^>]*href="([^"]+)"[^>]*/g
  let itemMatch: RegExpExecArray | null
  while ((itemMatch = itemRegex.exec(opfXml)) !== null) {
    manifestItems.set(itemMatch[1], itemMatch[2])
  }

  // Extract spine order: itemref idref values
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

    const fullPath = opfDir + href
    try {
      const xhtml = await zip.file(fullPath)?.async('text')
      if (!xhtml) {
        console.warn('[chunker] Could not read spine item:', fullPath)
        continue
      }

      // Extract chapter title from h1/h2/h3 before stripping tags
      const headingMatch = xhtml.match(/<h[1-3][^>]*>([\s\S]*?)<\/h[1-3]>/)
      const chapter = headingMatch
        ? headingMatch[1].replace(/<[^>]*>/g, '').trim() || idref
        : null

      // Strip HTML tags, collapse whitespace
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

/**
 * Split text sections into overlapping chunks respecting sentence boundaries.
 *
 * @param sections - Array of { text, chapter } from extractEpubText
 * @param maxChunkSize - Target max characters per chunk (default 500)
 * @param overlap - Number of overlap characters from previous chunk (default 50)
 * @returns Array of TextChunk objects with sequential chunkIndex
 */
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

    // Split by sentence boundaries
    const sentences = text.split(/(?<=[.!?])\s+/)

    let currentChunk = ''

    for (const sentence of sentences) {
      if (currentChunk.length + sentence.length + 1 > maxChunkSize && currentChunk.length > 0) {
        // Push current chunk
        chunks.push({
          id: randomUUID(),
          bookId: '',
          chunkIndex: chunkIndex++,
          text: currentChunk.trim(),
          chapter,
          createdAt: Date.now(),
        })

        // Start next chunk with overlap from previous
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

    // Push remaining text
    if (currentChunk.trim().length > 0) {
      chunks.push({
        id: randomUUID(),
        bookId: '',
        chunkIndex: chunkIndex++,
        text: currentChunk.trim(),
        chapter,
        createdAt: Date.now(),
      })
    }
  }

  return chunks
}

/**
 * Extract and chunk text from a book file.
 *
 * @param filePath - Path to the book file
 * @param format - Book format ('epub' or 'pdf')
 * @returns Array of TextChunk objects
 */
export async function getChunks(
  filePath: string,
  format: string
): Promise<TextChunk[]> {
  if (format === 'epub') {
    const sections = await extractEpubText(filePath)
    return chunkText(sections)
  }

  // PDF, MOBI, and DJVU text extraction not yet supported on mobile
  console.warn(`[chunker] ${format.toUpperCase()} text extraction not yet supported`)
  return []
}
