/**
 * MOBI / AZW3 (PalmDOC) binary parser.
 *
 * Ported from `apps/rishi-electron/src/main/ipc/formats.ts` and adjusted to be
 * platform-agnostic: the electron version used Node's `Buffer`; this module
 * works entirely with `Uint8Array` so it runs in React Native and the browser
 * (no `Buffer` global required). Vitest tests still use `Buffer.from(...)` to
 * construct fixtures because that's convenient under Node.
 *
 * Format references:
 *   https://wiki.mobileread.com/wiki/MOBI
 *   https://wiki.mobileread.com/wiki/PDB
 *   https://wiki.mobileread.com/wiki/PalmDOC
 */

// ---------- EXTH record types ----------

const EXTH_AUTHOR = 100
const EXTH_PUBLISHER = 101

// ---------- Big-endian helpers (Uint8Array-based) ----------

function readUInt16BE(buf: Uint8Array, offset: number): number {
  return (buf[offset] << 8) | buf[offset + 1]
}

function readUInt32BE(buf: Uint8Array, offset: number): number {
  // Multiply (not <<) for the high byte so we don't lose precision when the
  // result exceeds 2^31 (which `<<` would coerce to a signed Int32).
  return (
    buf[offset] * 0x1000000 +
    ((buf[offset + 1] << 16) | (buf[offset + 2] << 8) | buf[offset + 3])
  )
}

/**
 * Decode a slice of bytes as Latin-1, stopping at the first NUL.
 */
function decodeLatin1NulTerminated(buf: Uint8Array, start: number, end: number): string {
  let out = ''
  for (let i = start; i < end; i++) {
    const b = buf[i]
    if (b === 0) break
    out += String.fromCharCode(b)
  }
  return out
}

/**
 * Decode bytes as Latin-1 verbatim (used for the 4-byte EXTH magic).
 */
function decodeLatin1(buf: Uint8Array, start: number, end: number): string {
  let out = ''
  for (let i = start; i < end; i++) {
    out += String.fromCharCode(buf[i])
  }
  return out
}

/**
 * Decode bytes as UTF-8, falling back to single-byte decoding on the
 * (very unlikely) absence of TextDecoder.
 */
function decodeUtf8(buf: Uint8Array, start: number, end: number): string {
  const slice = buf.subarray(start, end)
  if (typeof TextDecoder !== 'undefined') {
    return new TextDecoder('utf-8', { fatal: false }).decode(slice)
  }
  let out = ''
  for (let i = 0; i < slice.length; i++) {
    out += String.fromCharCode(slice[i])
  }
  return out
}

// ---------- Types ----------

interface PdbRecord {
  offset: number
  id: number
}

export interface MobiHeader {
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
  data: Uint8Array
}

// ---------- PDB header parsing ----------

/**
 * Parse PDB header record entries from a MOBI file buffer.
 *
 * The PDB header layout:
 *   - bytes 0..32  : PDB name (NUL-terminated)
 *   - bytes 0x4C..0x4D : record count (uint16 BE)
 *   - bytes 0x4E..   : record entries (each: offset uint32 BE, id uint32 BE)
 */
function parsePdbRecords(buf: Uint8Array): {
  name: string
  recordCount: number
  records: PdbRecord[]
} {
  if (buf.length < 0x4e) {
    return { name: '', recordCount: 0, records: [] }
  }

  const name = decodeLatin1NulTerminated(buf, 0, 32)
  const recordCount = readUInt16BE(buf, 0x4c)

  const records: PdbRecord[] = []
  const recordListStart = 0x4e // 78
  for (let i = 0; i < recordCount; i++) {
    const entryOffset = recordListStart + i * 8
    if (entryOffset + 8 > buf.length) break
    const offset = readUInt32BE(buf, entryOffset)
    const rawId = readUInt32BE(buf, entryOffset + 4)
    records.push({ offset, id: rawId & 0x00ffffff })
  }

  return { name, recordCount, records }
}

/**
 * Parse the MOBI header from record 0 data.
 */
function parseMobiHeader(record0: Uint8Array): MobiHeader {
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
 * EXTH header starts right after the MOBI header (at offset 16 + headerLength).
 */
export function parseExthRecords(record0: Uint8Array, headerLength: number): ExthRecord[] {
  const exthOffset = 16 + headerLength
  if (exthOffset + 12 > record0.length) return []

  const magic = decodeLatin1(record0, exthOffset, exthOffset + 4)
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

// ---------- PalmDOC decompression ----------

/**
 * PalmDoc LZ77 decompression.
 *
 * The encoded stream uses these byte ranges:
 *   - 0x00              : literal NUL byte
 *   - 0x01..0x08        : "copy next N bytes literally"
 *   - 0x09..0x7F        : literal ASCII character
 *   - 0x80..0xBF        : two-byte LZ77 distance/length pair (offset & length)
 *   - 0xC0..0xFF        : a space followed by (byte XOR 0x80)
 */
export function palmdocDecompress(data: Uint8Array): string {
  let result = ''
  let i = 0

  while (i < data.length) {
    const byte = data[i]
    i += 1

    if (byte === 0) {
      result += '\0'
    } else if (byte >= 1 && byte <= 8) {
      for (let j = 0; j < byte && i < data.length; j++) {
        result += String.fromCharCode(data[i])
        i += 1
      }
    } else if (byte < 128) {
      result += String.fromCharCode(byte)
    } else if (byte >= 192) {
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
function trimRecord(data: Uint8Array, flags: number): Uint8Array {
  let trailers = 0
  const multibyte = flags & 1
  let f = flags >> 1
  while (f > 0) {
    trailers += 1
    f = f & (f - 1)
  }

  let trimmed = data

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
function extractMobiContent(
  buf: Uint8Array,
  pdbRecords: PdbRecord[],
  header: MobiHeader
): string {
  let content = ''

  for (let i = 1; i <= header.textRecordCount; i++) {
    if (i >= pdbRecords.length) break
    const start = pdbRecords[i].offset
    const end = i + 1 < pdbRecords.length ? pdbRecords[i + 1].offset : buf.length
    let recordData = buf.subarray(start, end)

    if (header.flags > 0) {
      recordData = trimRecord(recordData, header.flags)
    }

    if (header.compression === 1) {
      content += decodeUtf8(recordData, 0, recordData.length)
    } else if (header.compression === 2) {
      content += palmdocDecompress(recordData)
    }
    // compression === 17480 (HUFF/CDIC) is not supported
  }

  return content
}

/**
 * Extract the first image record as a cover image.
 * Returns both the image bytes and the detected MIME type.
 * Internal helper — public callers use `extractMobiCover(buf)` below.
 */
function extractMobiCover_impl(
  buf: Uint8Array,
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
export function parseMobiChapters(buf: Uint8Array): string[] {
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
export function parseMobiMetadata(buf: Uint8Array): {
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

  let title: string | null = null
  if (
    header.fullNameOffset > 0 &&
    header.fullNameLength > 0 &&
    header.fullNameOffset + header.fullNameLength <= record0.length
  ) {
    title = decodeUtf8(
      record0,
      header.fullNameOffset,
      header.fullNameOffset + header.fullNameLength
    ).replace(/\0/g, '')
    if (title.length === 0) title = null
  }

  let author: string | null = null
  let publisher: string | null = null

  if (header.exthFlags) {
    const exthRecords = parseExthRecords(record0, header.headerLength)
    for (const rec of exthRecords) {
      const text = decodeUtf8(rec.data, 0, rec.data.length).trim()
      if (text.length === 0) continue
      if (rec.type === EXTH_AUTHOR && !author) {
        author = text
      } else if (rec.type === EXTH_PUBLISHER && !publisher) {
        publisher = text
      }
    }
  }

  const { data: cover, mimeType: coverMimeType } = extractMobiCover_impl(buf, records, header)

  return { title, author, publisher, cover, coverMimeType }
}

/**
 * Public cover-extraction shape matching `extractEpubCover` — `mimeType`
 * plus raw bytes as Uint8Array (vs the internal helper's `number[]`),
 * so the mobile CoverPort can write the cover file with the same code
 * path it uses for EPUB.
 */
export interface MobiCover {
  mimeType: string
  data: Uint8Array
}

/**
 * Extract the first image record as a cover. Returns null when the
 * MOBI has no `firstImageIndex`, the record is too small, or the bytes
 * don't have a recognised JPEG / PNG / GIF magic.
 *
 * This is a thin wrapper around the existing internal extractor — the
 * public shape matches `extractEpubCover` so both formats plug into
 * the same `CoverPort` adapter on mobile.
 */
export function extractMobiCover(buf: Uint8Array): MobiCover | null {
  const { records } = parsePdbRecords(buf)
  if (records.length < 2) return null

  const record0 = buf.subarray(records[0].offset, records[1].offset)
  const header = parseMobiHeader(record0)
  const { data, mimeType } = extractMobiCover_impl(buf, records, header)
  if (data.length === 0 || mimeType === null) return null
  return { mimeType, data: Uint8Array.from(data) }
}

/**
 * Convenience: extract chapters as plain-text paragraphs split on newlines.
 * Useful for RAG chunking on MOBI/AZW3 where we want text rather than HTML.
 */
export function parseMobiTextParagraphs(buf: Uint8Array): string[][] {
  const chapters = parseMobiChapters(buf)
  return chapters.map((chapterHtml) =>
    stripHtmlTags(chapterHtml)
      .split(/\n/)
      .map((l) => l.trim())
      .filter((l) => l.length > 0)
  )
}
