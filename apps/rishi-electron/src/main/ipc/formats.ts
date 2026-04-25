import { ipcMain } from 'electron'
import * as fs from 'node:fs/promises'
import * as path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import * as os from 'node:os'
import * as crypto from 'node:crypto'

const execFileAsync = promisify(execFile)

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

interface EpubMetadata {
  title?: string
  creator?: string
  publisher?: string
  identifier?: string
}

async function extractEpubData(filePath: string): Promise<BookDataResult> {
  // Dynamic import for epubjs — CJS module has double-wrapped default when
  // loaded via ESM dynamic import in Electron's main process.
  const epubjs = await import('epubjs')
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const mod = epubjs.default as any
  const ePub: typeof epubjs.default = typeof mod === 'function' ? mod : mod.default
  const data = await fs.readFile(filePath)
  const book = ePub(data.buffer)
  await book.ready

  const metadata: EpubMetadata = book.packaging?.metadata ?? {}

  // Try to extract cover image
  let cover: number[] = []
  let coverKind: string | null = null
  try {
    // book.coverUrl() creates blob URLs requiring browser APIs and can hang
    // in Node.js. Use a timeout to prevent the handler from never resolving.
    const coverPromise = (async () => {
      const coverUrl = await book.coverUrl()
      if (coverUrl) {
        const response = await fetch(coverUrl)
        if (!response.ok) return
        const blob = await response.arrayBuffer()
        cover = Array.from(new Uint8Array(blob))
        coverKind = 'image/png'
      }
    })()
    const timeout = new Promise<void>((_, reject) =>
      setTimeout(() => reject(new Error('Cover extraction timed out')), 5000)
    )
    await Promise.race([coverPromise, timeout])
  } catch {
    // No cover available or extraction timed out
  }

  book.destroy()

  return {
    id: metadata.identifier ?? path.basename(filePath, '.epub'),
    kind: 'epub',
    cover,
    title: metadata.title ?? null,
    author: metadata.creator ?? null,
    publisher: metadata.publisher ?? null,
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

// ==========================================================================
// DJVU — CLI-based implementation using djvulibre tools
// ==========================================================================

/**
 * Check whether a CLI tool is available on the system.
 */
async function isToolAvailable(tool: string): Promise<boolean> {
  try {
    const cmd = process.platform === 'win32' ? 'where' : 'which'
    await execFileAsync(cmd, [tool])
    return true
  } catch {
    return false
  }
}

/**
 * Run a djvulibre CLI command safely using execFile (no shell injection).
 * Throws a descriptive error if the tool is not installed.
 */
async function runDjvuCommand(
  tool: string,
  args: string[],
  options?: { maxBuffer?: number; encoding?: BufferEncoding }
): Promise<{ stdout: string; stderr: string }> {
  const available = await isToolAvailable(tool)
  if (!available) {
    throw new Error(
      `${tool} is not installed. Install djvulibre to enable DJVU support. ` +
        `On macOS: brew install djvulibre | On Ubuntu/Debian: sudo apt install djvulibre-bin | ` +
        `On Fedora: sudo dnf install djvulibre`
    )
  }

  return execFileAsync(tool, args, {
    maxBuffer: options?.maxBuffer ?? 50 * 1024 * 1024, // 50MB
    encoding: options?.encoding ?? 'utf8'
  })
}

async function extractDjvuData(filePath: string): Promise<BookDataResult> {
  // Validate file exists
  try {
    await fs.access(filePath)
  } catch {
    throw new Error(`File not found: ${filePath}`)
  }

  // Validate DJVU magic bytes (AT&T)
  const fd = await fs.open(filePath, 'r')
  const magicBuf = Buffer.alloc(4)
  await fd.read(magicBuf, 0, 4, 0)
  await fd.close()

  if (magicBuf.toString('latin1') !== 'AT&T') {
    throw new Error(`Not a valid DJVU file (missing AT&T magic bytes): ${filePath}`)
  }

  const basename = path.basename(filePath, path.extname(filePath))
  const md5Hash = crypto.createHash('md5').update(filePath).digest('hex')

  // Try to extract metadata via djvused
  let title: string | null = basename
  let author: string | null = null
  let publisher: string | null = null

  try {
    const { stdout } = await runDjvuCommand('djvused', [filePath, '-e', 'print-meta'])

    // Parse djvused metadata output (key\t"value" format)
    for (const line of stdout.split('\n')) {
      const match = line.match(/^(\w+)\s+"(.+)"$/)
      if (!match) continue
      const [, key, value] = match
      if (key === 'title' && value) title = value
      if (key === 'author' && value) author = value
      if (key === 'publisher' && value) publisher = value
    }
  } catch {
    // djvused not available or metadata extraction failed — use filename as title
  }

  return {
    id: md5Hash,
    kind: 'djvu',
    cover: [], // DJVU doesn't embed cover images; placeholder generated by frontend
    title,
    author,
    publisher,
    filepath: filePath,
    location: '1',
    coverKind: 'fallback',
    version: 1
  }
}

/**
 * Render a DJVU page to RGBA pixel data.
 *
 * Uses ddjvu to render to PPM, then converts PPM RGB data to RGBA for canvas rendering.
 * Returns number[] of RGBA pixel values matching the frontend's ImageData expectations.
 */
async function renderDjvuPage(
  filePath: string,
  pageNumber: number,
  dpi: number
): Promise<number[]> {
  if (dpi <= 0 || dpi > 600) {
    throw new Error(`DPI must be between 1 and 600, got ${dpi}`)
  }

  const width = dpi * 8
  const height = dpi * 11

  // Render to a temp file to avoid pipe buffer limits
  const tmpFile = path.join(
    os.tmpdir(),
    `rishi_djvu_${process.pid}_${pageNumber}_${Date.now()}.ppm`
  )

  try {
    await runDjvuCommand('ddjvu', [
      '-format=ppm',
      `-page=${pageNumber}`,
      `-size=${width}x${height}`,
      filePath,
      tmpFile
    ])

    const ppmData = await fs.readFile(tmpFile)

    // Parse PPM format (P6 binary)
    // Header: P6\n<width> <height>\n<maxval>\n<pixel data>
    const headerEnd = findPpmHeaderEnd(ppmData)
    if (headerEnd < 0) {
      throw new Error('Invalid PPM file format')
    }

    const header = ppmData.subarray(0, headerEnd).toString('ascii')
    const parts = header.split(/\s+/)
    // parts: ["P6", width, height, maxval]
    const ppmWidth = parseInt(parts[1], 10)
    const ppmHeight = parseInt(parts[2], 10)

    const pixelData = ppmData.subarray(headerEnd)
    const rgbaPixels: number[] = new Array(ppmWidth * ppmHeight * 4)

    // Convert RGB to RGBA
    for (let i = 0; i < ppmWidth * ppmHeight; i++) {
      const rgbIdx = i * 3
      const rgbaIdx = i * 4
      rgbaPixels[rgbaIdx] = pixelData[rgbIdx] ?? 0 // R
      rgbaPixels[rgbaIdx + 1] = pixelData[rgbIdx + 1] ?? 0 // G
      rgbaPixels[rgbaIdx + 2] = pixelData[rgbIdx + 2] ?? 0 // B
      rgbaPixels[rgbaIdx + 3] = 255 // A
    }

    return rgbaPixels
  } finally {
    // Clean up temp file
    try {
      await fs.unlink(tmpFile)
    } catch {
      // Ignore cleanup errors
    }
  }
}

/**
 * Find the byte offset where PPM pixel data begins.
 * PPM P6 format has a header with magic, width, height, maxval separated by whitespace,
 * and pixel data starts after a single whitespace character following maxval.
 */
function findPpmHeaderEnd(data: Buffer): number {
  let fieldCount = 0 // We need 4 fields: magic, width, height, maxval
  let i = 0
  let inWhitespace = false
  let inComment = false

  while (i < data.length && fieldCount < 4) {
    const ch = data[i]

    if (inComment) {
      if (ch === 0x0a) {
        // newline
        inComment = false
      }
      i++
      continue
    }

    if (ch === 0x23) {
      // '#' comment
      inComment = true
      i++
      continue
    }

    const isWs = ch === 0x20 || ch === 0x09 || ch === 0x0a || ch === 0x0d

    if (isWs) {
      if (!inWhitespace) {
        fieldCount++
        inWhitespace = true
      }
      if (fieldCount === 4) {
        return i + 1 // Pixel data starts after this whitespace byte
      }
    } else {
      inWhitespace = false
    }

    i++
  }

  return -1
}

/**
 * Get the total page count of a DJVU file.
 */
async function getDjvuPageCountImpl(filePath: string): Promise<number> {
  const { stdout } = await runDjvuCommand('djvused', [filePath, '-e', 'n'])
  const count = parseInt(stdout.trim(), 10)
  if (isNaN(count)) {
    throw new Error(`Failed to parse page count from djvused output: ${stdout}`)
  }
  return count
}

/**
 * Extract text from a single DJVU page.
 */
async function getDjvuPageTextImpl(filePath: string, pageNumber: number): Promise<string[]> {
  try {
    const { stdout } = await runDjvuCommand('djvutxt', [`--page=${pageNumber}`, filePath])

    return stdout
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l.length > 0)
  } catch {
    // No text layer or tool failure — return empty
    return []
  }
}

// ---------- Register handlers ----------

export function registerFormatHandlers(): void {
  // --- EPUB ---
  ipcMain.handle('formats:getBookData', async (_event, filePath: string) => {
    try {
      return await extractEpubData(filePath)
    } catch (error) {
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

  // --- DJVU ---
  ipcMain.handle('formats:getDjvuData', async (_event, filePath: string) => {
    try {
      return await extractDjvuData(filePath)
    } catch (error) {
      throw new Error(
        `Failed to extract DJVU data from "${filePath}": ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle(
    'formats:getDjvuPage',
    async (_event, filePath: string, pageNumber: number, dpi: number) => {
      try {
        return await renderDjvuPage(filePath, pageNumber, dpi)
      } catch (error) {
        throw new Error(
          `Failed to get DJVU page: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )

  ipcMain.handle('formats:getDjvuPageCount', async (_event, filePath: string) => {
    try {
      return await getDjvuPageCountImpl(filePath)
    } catch (error) {
      throw new Error(
        `Failed to get DJVU page count: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  })

  ipcMain.handle(
    'formats:getDjvuPageText',
    async (_event, filePath: string, pageNumber: number) => {
      try {
        return await getDjvuPageTextImpl(filePath, pageNumber)
      } catch (error) {
        throw new Error(
          `Failed to get DJVU page text: ${error instanceof Error ? error.message : String(error)}`
        )
      }
    }
  )
}
