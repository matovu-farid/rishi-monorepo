import { ipcMain } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import * as crypto from 'node:crypto'
import JSZip from 'jszip'

// ---------- Shared types ----------

interface BookDataResult {
  id: string
  kind: string
  cover: number[]
  title: string | null
  author: string | null
  publisher: string | null
  filepath: string
  location: string
  coverKind: string | null
  version: number
}

// ---------- EPUB ----------

async function extractEpubData(filePath: string): Promise<BookDataResult> {
  // Parse EPUB using jszip directly — epubjs is a browser-only library that
  // hangs in Node.js because it relies on DOM APIs (DOMParser, XMLHttpRequest).
  // EPUBs are ZIP files with a standard OPF metadata structure.
  const data = await fs.readFile(filePath)
  const zip = await JSZip.loadAsync(data)

  let title: string | null = null
  let author: string | null = null
  let publisher: string | null = null
  let identifier: string | null = null
  let cover: number[] = []
  let coverKind: string | null = null
  let coverHref: string | null = null

  // 1. Find the OPF file path from META-INF/container.xml
  let opfPath = 'OEBPS/content.opf' // fallback
  const containerXml = await zip.file('META-INF/container.xml')?.async('text')
  if (containerXml) {
    const rootfileMatch = containerXml.match(/full-path="([^"]+)"/)
    if (rootfileMatch) opfPath = rootfileMatch[1]
  }

  // 2. Parse OPF for metadata
  const opfContent = await zip.file(opfPath)?.async('text')
  if (opfContent) {
    // Extract metadata using regex (no DOM parser needed in Node.js)
    const titleMatch = opfContent.match(/<dc:title[^>]*>([^<]+)<\/dc:title>/i)
    if (titleMatch) title = titleMatch[1].trim()

    const creatorMatch = opfContent.match(/<dc:creator[^>]*>([^<]+)<\/dc:creator>/i)
    if (creatorMatch) author = creatorMatch[1].trim()

    const publisherMatch = opfContent.match(/<dc:publisher[^>]*>([^<]+)<\/dc:publisher>/i)
    if (publisherMatch) publisher = publisherMatch[1].trim()

    const identifierMatch = opfContent.match(/<dc:identifier[^>]*>([^<]+)<\/dc:identifier>/i)
    if (identifierMatch) identifier = identifierMatch[1].trim()

    // 3. Find cover image
    // Look for meta cover reference: <meta name="cover" content="cover-image"/>
    const coverMetaMatch = opfContent.match(/<meta\s+name="cover"\s+content="([^"]+)"/i)
    const coverId = coverMetaMatch?.[1]

    if (coverId) {
      // Find the manifest item with that id — attributes can be in any order
      const escapedId = coverId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      // Try id before href
      const r1 = new RegExp(`<item[^>]+id="${escapedId}"[^>]+href="([^"]+)"`, 'i')
      // Try href before id
      const r2 = new RegExp(`<item[^>]+href="([^"]+)"[^>]+id="${escapedId}"`, 'i')
      const m1 = opfContent.match(r1)
      const m2 = opfContent.match(r2)
      if (m1) coverHref = m1[1]
      else if (m2) coverHref = m2[1]
    }

    // Fallback: look for item with properties="cover-image" (either attribute order)
    if (!coverHref) {
      const p1 = opfContent.match(/<item[^>]+properties="cover-image"[^>]+href="([^"]+)"/i)
      const p2 = opfContent.match(/<item[^>]+href="([^"]+)"[^>]+properties="cover-image"/i)
      if (p1) coverHref = p1[1]
      else if (p2) coverHref = p2[1]
    }

    // Fallback: look for item with id containing "cover" and image media-type (either order)
    if (!coverHref) {
      const coverIdMatch =
        opfContent.match(
          /<item[^>]+id="[^"]*cover[^"]*"[^>]+href="([^"]+)"[^>]+media-type="image\/[^"]+"/i
        ) ??
        opfContent.match(
          /<item[^>]+href="([^"]+)"[^>]+id="[^"]*cover[^"]*"[^>]+media-type="image\/[^"]+"/i
        )
      if (coverIdMatch) coverHref = coverIdMatch[1]
    }
  }

  // 4. Extract cover image bytes
  if (coverHref) {
    // Resolve cover path relative to OPF directory
    const opfDir = opfPath.includes('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : ''
    const coverPath = coverHref.startsWith('/') ? coverHref.slice(1) : opfDir + coverHref
    const coverFile = zip.file(coverPath) ?? zip.file(coverHref)
    if (coverFile) {
      const coverData = await coverFile.async('uint8array')
      cover = Array.from(coverData)
      // Detect image type from extension
      const ext = coverHref.toLowerCase()
      if (ext.endsWith('.png')) coverKind = 'image/png'
      else if (ext.endsWith('.jpg') || ext.endsWith('.jpeg')) coverKind = 'image/jpeg'
      else if (ext.endsWith('.gif')) coverKind = 'image/gif'
      else coverKind = 'image/jpeg' // default
    }
  }

  return {
    id: identifier ?? path.basename(filePath, '.epub'),
    kind: 'epub',
    cover,
    title: title ?? null,
    author: author ?? null,
    publisher: publisher ?? null,
    filepath: filePath,
    location: '',
    coverKind,
    version: 1
  }
}

// ---------- PDF ----------

async function extractPdfData(filePath: string): Promise<BookDataResult> {
  const pdfParse = (await import('pdf-parse')).default
  const data = await fs.readFile(filePath)
  const pdf = await pdfParse(data)

  const info = pdf.info ?? {}

  return {
    id: (info.PDFFormatVersion ?? '') + '-' + path.basename(filePath, '.pdf'),
    kind: 'pdf',
    cover: [],
    title: info.Title ?? null,
    author: info.Author ?? null,
    publisher: info.Producer ?? null,
    filepath: filePath,
    location: '',
    coverKind: null,
    version: 1
  }
}

// ==========================================================================
// MOBI — Binary parser for PDB/MOBI/EXTH format
// ==========================================================================

// Known EXTH record type IDs
const EXTH_AUTHOR = 100
const EXTH_PUBLISHER = 101

/**
 * Read a big-endian uint16 from a buffer at the given offset.
 */
function readUInt16BE(buf: Buffer, offset: number): number {
  return buf.readUInt16BE(offset)
}

/**
 * Read a big-endian uint32 from a buffer at the given offset.
 */
function readUInt32BE(buf: Buffer, offset: number): number {
  return buf.readUInt32BE(offset)
}

interface PdbRecord {
  offset: number
  id: number
}

interface MobiHeader {
  compression: number
  textLength: number
  textRecordCount: number
  recordSize: number
  encryption: number
  headerLength: number
  encoding: number
  fullNameOffset: number
  fullNameLength: number
  firstImageIndex: number
  exthFlags: boolean
  firstNonBookIndex: number
  flags: number
}

interface ExthRecord {
  type: number
  data: Buffer
}

/**
 * Parse PDB header record entries from a MOBI file buffer.
 */
function parsePdbRecords(buf: Buffer): { name: string; recordCount: number; records: PdbRecord[] } {
  // Minimum PDB header size: 0x4E (78) bytes for record count + at least one record entry
  if (buf.length < 0x4e) {
    return { name: '', recordCount: 0, records: [] }
  }

  // PDB name: first 32 bytes (null-terminated)
  const nameRaw = buf.subarray(0, 32)
  const nullIdx = nameRaw.indexOf(0)
  const name = nameRaw.subarray(0, nullIdx === -1 ? 32 : nullIdx).toString('latin1')

  // Record count at offset 0x4C (76)
  const recordCount = readUInt16BE(buf, 0x4c)

  const records: PdbRecord[] = []
  const recordListStart = 0x4e // 78
  for (let i = 0; i < recordCount; i++) {
    const entryOffset = recordListStart + i * 8
    const offset = readUInt32BE(buf, entryOffset)
    const rawId = readUInt32BE(buf, entryOffset + 4)
    records.push({ offset, id: rawId & 0x00ffffff })
  }

  return { name, recordCount, records }
}

/**
 * Parse the MOBI header from record 0 data.
 */
function parseMobiHeader(record0: Buffer): MobiHeader {
  const compression = readUInt16BE(record0, 0)
  const textLength = readUInt32BE(record0, 4)
  const textRecordCount = readUInt16BE(record0, 8)
  const recordSize = readUInt16BE(record0, 10)
  const encryption = readUInt16BE(record0, 12)

  // MOBI header starts at offset 16 in record 0
  const headerLength = readUInt32BE(record0, 0x14)
  const encoding = readUInt32BE(record0, 0x1c)

  const firstNonBookIndex = readUInt32BE(record0, 0x50)
  const fullNameOffset = readUInt32BE(record0, 0x54)
  const fullNameLength = readUInt32BE(record0, 0x58)

  let firstImageIndex = 0
  if (record0.length > 0x6c + 4) {
    firstImageIndex = readUInt32BE(record0, 0x6c)
  }

  let exthFlags = false
  if (record0.length > 0x80 + 4) {
    const rawFlags = readUInt32BE(record0, 0x80)
    exthFlags = (rawFlags & 0x40) === 0x40
  }

  let flags = 0
  if (headerLength >= 0xe4 && record0.length > 0xf2 + 2) {
    flags = readUInt16BE(record0, 0xf2)
  }

  return {
    compression,
    textLength,
    textRecordCount,
    recordSize,
    encryption,
    headerLength,
    encoding,
    fullNameOffset,
    fullNameLength,
    firstImageIndex,
    exthFlags,
    firstNonBookIndex,
    flags
  }
}

/**
 * Parse EXTH records from record 0, if present.
 * EXTH header starts right after the MOBI header (at offset 16 + headerLength in record 0).
 */
function parseExthRecords(record0: Buffer, headerLength: number): ExthRecord[] {
  // EXTH header starts at offset 16 (PalmDOC header) + headerLength (MOBI header)
  const exthOffset = 16 + headerLength
  if (exthOffset + 12 > record0.length) return []

  // Check EXTH magic "EXTH"
  const magic = record0.subarray(exthOffset, exthOffset + 4).toString('latin1')
  if (magic !== 'EXTH') return []

  const recordCount = readUInt32BE(record0, exthOffset + 8)
  const records: ExthRecord[] = []

  let pos = exthOffset + 12
  for (let i = 0; i < recordCount; i++) {
    if (pos + 8 > record0.length) break
    const type = readUInt32BE(record0, pos)
    const length = readUInt32BE(record0, pos + 4)
    if (length < 8 || pos + length > record0.length) break
    const data = record0.subarray(pos + 8, pos + length)
    records.push({ type, data })
    pos += length
  }

  return records
}

/**
 * PalmDoc LZ77 decompression.
 */
function palmdocDecompress(data: Buffer): string {
  let result = ''
  let i = 0

  while (i < data.length) {
    const byte = data[i]
    i += 1

    if (byte === 0) {
      // Literal null byte
      result += '\0'
    } else if (byte >= 1 && byte <= 8) {
      // Copy next 'byte' bytes literally
      for (let j = 0; j < byte && i < data.length; j++) {
        result += String.fromCharCode(data[i])
        i += 1
      }
    } else if (byte < 128) {
      // Literal character
      result += String.fromCharCode(byte)
    } else if (byte >= 192) {
      // Space + character
      result += ' ' + String.fromCharCode(byte ^ 128)
    } else {
      // LZ77 distance/length pair
      if (i >= data.length) break
      const nextByte = data[i]
      i += 1
      const combined = (byte << 8) | nextByte
      const distance = (combined >> 3) & 0x07ff
      const length = (combined & 7) + 3

      if (distance > 0) {
        for (let j = 0; j < length; j++) {
          const srcIdx = result.length - distance
          if (srcIdx >= 0 && srcIdx < result.length) {
            result += result[srcIdx]
          }
        }
      }
    }
  }

  return result
}

/**
 * Trim trailing bytes from a record (trailers and multibyte indicator).
 */
function trimRecord(data: Buffer, flags: number): Buffer {
  let trailers = 0
  const multibyte = flags & 1
  let f = flags >> 1
  while (f > 0) {
    trailers += 1
    f = f & (f - 1)
  }

  let trimmed = data

  // Remove trailers
  for (let t = 0; t < trailers; t++) {
    if (trimmed.length < 4) break
    const endBytes = trimmed.subarray(trimmed.length - 4)
    let num = 0
    for (let v = 0; v < 4; v++) {
      if (endBytes[v] & 0x80) {
        num = 0
      }
      num = (num << 7) | (endBytes[v] & 0x7f)
    }
    if (num > 0 && num <= trimmed.length) {
      trimmed = trimmed.subarray(0, trimmed.length - num)
    }
  }

  // Remove multibyte indicator
  if (multibyte && trimmed.length > 0) {
    const num = (trimmed[trimmed.length - 1] & 3) + 1
    if (num <= trimmed.length) {
      trimmed = trimmed.subarray(0, trimmed.length - num)
    }
  }

  return trimmed
}

/**
 * Extract the full HTML content from a MOBI file buffer.
 */
function extractMobiContent(buf: Buffer, pdbRecords: PdbRecord[], header: MobiHeader): string {
  let content = ''

  for (let i = 1; i <= header.textRecordCount; i++) {
    if (i >= pdbRecords.length) break
    const start = pdbRecords[i].offset
    const end = i + 1 < pdbRecords.length ? pdbRecords[i + 1].offset : buf.length
    let recordData = buf.subarray(start, end)

    // Trim trailing bytes if flags are present
    if (header.flags > 0) {
      recordData = trimRecord(recordData, header.flags)
    }

    if (header.compression === 1) {
      // No compression
      content += recordData.toString('utf8')
    } else if (header.compression === 2) {
      // PalmDoc compression
      content += palmdocDecompress(recordData)
    }
    // compression === 17480 (HUFF/CDIC) is not supported
  }

  return content
}

/**
 * Extract the first image record as a cover image.
 * Returns both the image bytes and the detected MIME type.
 */
function extractMobiCover(
  buf: Buffer,
  pdbRecords: PdbRecord[],
  header: MobiHeader
): { data: number[]; mimeType: string | null } {
  if (header.firstImageIndex <= 0 || header.firstImageIndex >= pdbRecords.length) {
    return { data: [], mimeType: null }
  }

  const start = pdbRecords[header.firstImageIndex].offset
  const end =
    header.firstImageIndex + 1 < pdbRecords.length
      ? pdbRecords[header.firstImageIndex + 1].offset
      : buf.length

  const imageData = buf.subarray(start, end)

  // Verify it looks like an image (JPEG, PNG, or GIF magic bytes)
  if (imageData.length < 4) return { data: [], mimeType: null }
  const isJpeg = imageData[0] === 0xff && imageData[1] === 0xd8
  const isPng = imageData[0] === 0x89 && imageData[1] === 0x50
  const isGif = imageData[0] === 0x47 && imageData[1] === 0x49

  if (!isJpeg && !isPng && !isGif) return { data: [], mimeType: null }

  const mimeType = isJpeg ? 'image/jpeg' : isPng ? 'image/png' : 'image/gif'
  return { data: Array.from(imageData), mimeType }
}

/**
 * Strip HTML tags from a string, returning plain text.
 */
export function stripHtmlTags(html: string): string {
  let result = ''
  let insideTag = false
  for (const ch of html) {
    if (ch === '<') {
      insideTag = true
    } else if (ch === '>') {
      insideTag = false
    } else if (!insideTag) {
      result += ch
    }
  }
  return result
}

/**
 * Parse a MOBI file and return its chapters (split by <mbp:pagebreak/>).
 */
export function parseMobiChapters(buf: Buffer): string[] {
  const { records } = parsePdbRecords(buf)
  if (records.length < 2) return []

  const record0 = buf.subarray(records[0].offset, records[1].offset)
  const header = parseMobiHeader(record0)
  const content = extractMobiContent(buf, records, header)

  const chapters = content
    .split('<mbp:pagebreak/>')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)

  if (chapters.length === 0) {
    return [content]
  }
  return chapters
}

/**
 * Parse MOBI file metadata including EXTH records for author/publisher.
 */
export function parseMobiMetadata(buf: Buffer): {
  title: string | null
  author: string | null
  publisher: string | null
  cover: number[]
  coverMimeType: string | null
} {
  const { records } = parsePdbRecords(buf)
  if (records.length < 2) {
    return { title: null, author: null, publisher: null, cover: [], coverMimeType: null }
  }

  const record0 = buf.subarray(records[0].offset, records[1].offset)
  const header = parseMobiHeader(record0)

  // Extract title from full name field
  let title: string | null = null
  if (
    header.fullNameOffset > 0 &&
    header.fullNameLength > 0 &&
    header.fullNameOffset + header.fullNameLength <= record0.length
  ) {
    title = record0
      .subarray(header.fullNameOffset, header.fullNameOffset + header.fullNameLength)
      .toString('utf8')
      .replace(/\0/g, '')
    if (title.length === 0) title = null
  }

  // Parse EXTH records for author and publisher
  let author: string | null = null
  let publisher: string | null = null

  if (header.exthFlags) {
    const exthRecords = parseExthRecords(record0, header.headerLength)
    for (const rec of exthRecords) {
      const text = rec.data.toString('utf8').trim()
      if (text.length === 0) continue
      if (rec.type === EXTH_AUTHOR && !author) {
        author = text
      } else if (rec.type === EXTH_PUBLISHER && !publisher) {
        publisher = text
      }
    }
  }

  // Extract cover image
  const { data: cover, mimeType: coverMimeType } = extractMobiCover(buf, records, header)

  return { title, author, publisher, cover, coverMimeType }
}

async function extractMobiData(filePath: string): Promise<BookDataResult> {
  const data = await fs.readFile(filePath)
  const buf = Buffer.from(data)

  const { title, author, publisher, cover, coverMimeType } = parseMobiMetadata(buf)
  const ext = path.extname(filePath)
  const basename = path.basename(filePath, ext)
  const md5Hash = crypto.createHash('md5').update(filePath).digest('hex')

  return {
    id: md5Hash,
    kind: 'mobi',
    cover,
    title: title ?? basename,
    author,
    publisher,
    filepath: filePath,
    location: '0',
    coverKind: coverMimeType ?? 'fallback',
    version: 1
  }
}

/**
 * Extract metadata from an AZW3 (Kindle KF8) file. AZW3 uses the same PDB
 * container as MOBI, so the existing MOBI header / EXTH parsers extract
 * title, author, publisher, and cover bytes. The renderer is responsible
 * for actually rendering the KF8 payload (via foliate-js).
 */
async function extractAzw3Data(filePath: string): Promise<BookDataResult> {
  const data = await fs.readFile(filePath)
  const buf = Buffer.from(data)

  let title: string | null = null
  let author: string | null = null
  let publisher: string | null = null
  let cover: number[] = []
  let coverMimeType: string | null = null

  try {
    const parsed = parseMobiMetadata(buf)
    title = parsed.title
    author = parsed.author
    publisher = parsed.publisher
    cover = parsed.cover
    coverMimeType = parsed.coverMimeType
  } catch {
    // Some KF8-only files have headers MOBI parsers don't fully understand;
    // we fall back to filename-derived metadata and let foliate-js do the
    // heavy lifting in the renderer.
  }

  const ext = path.extname(filePath)
  const basename = path.basename(filePath, ext)
  const md5Hash = crypto.createHash('md5').update(filePath).digest('hex')

  return {
    id: md5Hash,
    kind: 'azw3',
    cover,
    title: title ?? basename,
    author,
    publisher,
    filepath: filePath,
    location: '0',
    coverKind: coverMimeType ?? 'fallback',
    version: 1
  }
}

/**
 * Get all chapters from a MOBI file.
 */
async function getMobiChapters(filePath: string): Promise<string[]> {
  const data = await fs.readFile(filePath)
  const buf = Buffer.from(data)
  return parseMobiChapters(buf)
}

/**
 * Get HTML content for a single MOBI chapter.
 */
async function getMobiChapterHtml(filePath: string, chapterIndex: number): Promise<string> {
  const chapters = await getMobiChapters(filePath)
  if (chapterIndex < 0 || chapterIndex >= chapters.length) {
    throw new Error(`Chapter index ${chapterIndex} out of range (total ${chapters.length})`)
  }
  return chapters[chapterIndex]
}

/**
 * Get the number of chapters in a MOBI file.
 */
async function getMobiChapterCount(filePath: string): Promise<number> {
  const chapters = await getMobiChapters(filePath)
  return chapters.length
}

/**
 * Get plain-text paragraphs from a single MOBI chapter.
 */
async function getMobiChapterText(filePath: string, chapterIndex: number): Promise<string[]> {
  const html = await getMobiChapterHtml(filePath, chapterIndex)
  const plain = stripHtmlTags(html)
  return plain
    .split(/\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0)
}

// ---------- Register handlers ----------

export function registerFormatHandlers(): void {
  // --- EPUB ---
  ipcMain.handle('formats:getBookData', async (_event, filePath: string) => {
    console.log('[formats:getBookData] Called with:', filePath)
    try {
      const result = await extractEpubData(filePath)
      console.log(
        '[formats:getBookData] Success:',
        result.title,
        '- cover bytes:',
        result.cover.length
      )
      return result
    } catch (error) {
      console.error('[formats:getBookData] Error:', error)
      throw new Error(
        `Failed to extract EPUB data from "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  // --- PDF ---
  ipcMain.handle('formats:getPdfData', async (_event, filePath: string) => {
    try {
      return await extractPdfData(filePath)
    } catch (error) {
      throw new Error(
        `Failed to extract PDF data from "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  // --- MOBI ---
  ipcMain.handle('formats:getMobiData', async (_event, filePath: string) => {
    try {
      return await extractMobiData(filePath)
    } catch (error) {
      throw new Error(
        `Failed to extract MOBI data from "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  // --- AZW3 (Kindle KF8) ---
  ipcMain.handle('formats:getAzw3Data', async (_event, filePath: string) => {
    try {
      return await extractAzw3Data(filePath)
    } catch (error) {
      throw new Error(
        `Failed to extract AZW3 data from "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle(
    'formats:getMobiChapter',
    async (_event, filePath: string, chapterIndex: number) => {
      try {
        return await getMobiChapterHtml(filePath, chapterIndex)
      } catch (error) {
        throw new Error(
          `Failed to get MOBI chapter: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )

  ipcMain.handle('formats:getMobiChapterCount', async (_event, filePath: string) => {
    try {
      return await getMobiChapterCount(filePath)
    } catch (error) {
      throw new Error(
        `Failed to get MOBI chapter count: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle('formats:getMobiText', async (_event, filePath: string, chapterIndex: number) => {
    try {
      return await getMobiChapterText(filePath, chapterIndex)
    } catch (error) {
      throw new Error(
        `Failed to get MOBI text: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })
}
