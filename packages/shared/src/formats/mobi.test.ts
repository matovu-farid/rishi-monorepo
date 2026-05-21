import { describe, it, expect } from 'vitest'
import {
  stripHtmlTags,
  parseMobiChapters,
  parseMobiMetadata,
  parseMobiTextParagraphs,
  palmdocDecompress,
  extractMobiCover
} from './mobi'

// ---------------------------------------------------------------------------
// Helper: build a minimal MOBI file buffer for testing.
//
// A MOBI file is a PDB container with:
//   - PDB header (78 bytes + 8 bytes per record entry)
//   - Record 0: PalmDOC header (16 bytes) + MOBI header + optional EXTH + full name
//   - Records 1..N: text content records (uncompressed, compression=1)
//
// The original electron test builds this with Node `Buffer`. To stay platform-
// agnostic (the shared package targets RN too), we use `Uint8Array` +
// `DataView` for big-endian writes and a small `utf8Encode` helper, so the
// test exercises the same `Uint8Array` contract the parser supports.
// ---------------------------------------------------------------------------

function utf8Encode(str: string): Uint8Array {
  if (typeof TextEncoder !== 'undefined') {
    return new TextEncoder().encode(str)
  }
  // Fallback that covers the BMP — sufficient for our ASCII test fixtures.
  const out = new Uint8Array(str.length)
  for (let i = 0; i < str.length; i++) {
    out[i] = str.charCodeAt(i) & 0xff
  }
  return out
}

function writeUInt16BE(buf: Uint8Array, offset: number, value: number): void {
  buf[offset] = (value >> 8) & 0xff
  buf[offset + 1] = value & 0xff
}

function writeUInt32BE(buf: Uint8Array, offset: number, value: number): void {
  // Use division for the high byte so values above 2^31 round-trip correctly.
  buf[offset] = Math.floor(value / 0x1000000) & 0xff
  buf[offset + 1] = (value >> 16) & 0xff
  buf[offset + 2] = (value >> 8) & 0xff
  buf[offset + 3] = value & 0xff
}

function writeAscii(buf: Uint8Array, offset: number, str: string, maxLen: number): void {
  const slice = utf8Encode(str)
  const len = Math.min(slice.length, maxLen)
  for (let i = 0; i < len; i++) {
    buf[offset + i] = slice[i]
  }
}

function buildMobiBuffer(options: {
  title?: string
  author?: string
  publisher?: string
  content?: string
  compression?: number
}): Uint8Array {
  const title = options.title ?? 'Test Book'
  const author = options.author ?? ''
  const publisher = options.publisher ?? ''
  const content = options.content ?? '<p>Hello world</p>'
  const compression = options.compression ?? 1

  const hasExth = author.length > 0 || publisher.length > 0

  // --- Build EXTH records if needed ---
  let exthBlock = new Uint8Array(0)
  if (hasExth) {
    const exthRecords: Uint8Array[] = []

    if (author.length > 0) {
      const authorBytes = utf8Encode(author)
      const rec = new Uint8Array(8 + authorBytes.length)
      writeUInt32BE(rec, 0, 100) // type: author
      writeUInt32BE(rec, 4, 8 + authorBytes.length)
      rec.set(authorBytes, 8)
      exthRecords.push(rec)
    }

    if (publisher.length > 0) {
      const pubBytes = utf8Encode(publisher)
      const rec = new Uint8Array(8 + pubBytes.length)
      writeUInt32BE(rec, 0, 101) // type: publisher
      writeUInt32BE(rec, 4, 8 + pubBytes.length)
      rec.set(pubBytes, 8)
      exthRecords.push(rec)
    }

    const totalRecBytes = exthRecords.reduce((a, b) => a + b.length, 0)
    exthBlock = new Uint8Array(12 + totalRecBytes)
    writeAscii(exthBlock, 0, 'EXTH', 4)
    writeUInt32BE(exthBlock, 4, 12 + totalRecBytes)
    writeUInt32BE(exthBlock, 8, exthRecords.length)
    let pos = 12
    for (const rec of exthRecords) {
      exthBlock.set(rec, pos)
      pos += rec.length
    }
  }

  // --- Build MOBI header ---
  const mobiHeaderLength = 0xe8
  const fullNameOffset = 16 + mobiHeaderLength + exthBlock.length
  const titleBytes = utf8Encode(title)
  const record0Size = fullNameOffset + titleBytes.length
  const record0 = new Uint8Array(record0Size)

  // PalmDOC header (first 16 bytes of record 0)
  writeUInt16BE(record0, 0, compression)
  const contentBytes = utf8Encode(content)
  writeUInt32BE(record0, 4, contentBytes.length)
  writeUInt16BE(record0, 8, 1) // textRecordCount
  writeUInt16BE(record0, 10, 4096) // recordSize
  writeUInt16BE(record0, 12, 0) // encryption

  // MOBI header at offset 16
  writeAscii(record0, 16, 'MOBI', 4)
  writeUInt32BE(record0, 0x14, mobiHeaderLength)
  writeUInt32BE(record0, 0x18, 2) // mobiType
  writeUInt32BE(record0, 0x1c, 65001) // UTF-8 encoding
  writeUInt32BE(record0, 0x50, 2) // firstNonBookIndex
  writeUInt32BE(record0, 0x54, fullNameOffset)
  writeUInt32BE(record0, 0x58, titleBytes.length)
  writeUInt32BE(record0, 0x6c, 0) // firstImageIndex
  writeUInt32BE(record0, 0x80, hasExth ? 0x40 : 0x00)
  if (record0.length > 0xf2 + 2) {
    writeUInt16BE(record0, 0xf2, 0) // flags
  }

  if (exthBlock.length > 0) {
    record0.set(exthBlock, 16 + mobiHeaderLength)
  }
  record0.set(titleBytes, fullNameOffset)

  // --- Build PDB header ---
  const numRecords = 2
  const pdbHeaderSize = 0x4e + numRecords * 8
  const record0Offset = pdbHeaderSize
  const record1Offset = record0Offset + record0Size
  const totalSize = record1Offset + contentBytes.length
  const buf = new Uint8Array(totalSize)

  writeAscii(buf, 0, title.substring(0, 31), 32)
  writeUInt16BE(buf, 0x4c, numRecords)
  writeUInt32BE(buf, 0x4e, record0Offset)
  writeUInt32BE(buf, 0x4e + 4, 0) // record 0 id
  writeUInt32BE(buf, 0x4e + 8, record1Offset)
  writeUInt32BE(buf, 0x4e + 12, 1) // record 1 id

  buf.set(record0, record0Offset)
  buf.set(contentBytes, record1Offset)

  return buf
}

// ---------------------------------------------------------------------------
// stripHtmlTags
// ---------------------------------------------------------------------------

describe('stripHtmlTags', () => {
  it('strips simple tags', () => {
    expect(stripHtmlTags('<p>hello</p>')).toBe('hello')
  })

  it('strips nested tags', () => {
    expect(stripHtmlTags('<div><span>text</span></div>')).toBe('text')
  })

  it('handles empty string', () => {
    expect(stripHtmlTags('')).toBe('')
  })

  it('returns plain text unchanged', () => {
    expect(stripHtmlTags('plain text')).toBe('plain text')
  })

  it('strips tags with attributes', () => {
    expect(stripHtmlTags('<a href="url">link</a>')).toBe('link')
  })

  it('handles self-closing tags', () => {
    expect(stripHtmlTags('before<br/>after')).toBe('beforeafter')
  })
})

// ---------------------------------------------------------------------------
// parseMobiMetadata
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// extractMobiCover — N08
// ---------------------------------------------------------------------------

/**
 * Build a MOBI buffer that includes a fake image record after the
 * single text record. The exporter sets `firstImageIndex` to point at
 * that record (index 2 in this fixture). The image data is a tiny JPEG
 * magic prefix (`FF D8 FF`) followed by a couple of bytes — enough to
 * pass `extractMobiCover_impl`'s magic-byte check.
 */
function buildMobiBufferWithCover(opts: {
  imageMagic: 'jpg' | 'png' | 'gif' | 'invalid'
}): Uint8Array {
  const title = 'With Cover'
  const content = '<p>text</p>'
  const contentBytes = utf8Encode(content)

  // Image record bytes
  let imageBytes: Uint8Array
  switch (opts.imageMagic) {
    case 'jpg':
      imageBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10])
      break
    case 'png':
      imageBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      break
    case 'gif':
      imageBytes = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
      break
    case 'invalid':
      imageBytes = new Uint8Array([0xde, 0xad, 0xbe, 0xef])
      break
  }

  // Build record 0
  const mobiHeaderLength = 0xe8
  const titleBytes = utf8Encode(title)
  const fullNameOffset = 16 + mobiHeaderLength
  const record0Size = fullNameOffset + titleBytes.length
  const record0 = new Uint8Array(record0Size)

  writeUInt16BE(record0, 0, 1) // uncompressed
  writeUInt32BE(record0, 4, contentBytes.length)
  writeUInt16BE(record0, 8, 1) // textRecordCount
  writeUInt16BE(record0, 10, 4096)
  writeUInt16BE(record0, 12, 0)

  writeAscii(record0, 16, 'MOBI', 4)
  writeUInt32BE(record0, 0x14, mobiHeaderLength)
  writeUInt32BE(record0, 0x18, 2)
  writeUInt32BE(record0, 0x1c, 65001)
  writeUInt32BE(record0, 0x50, 2)
  writeUInt32BE(record0, 0x54, fullNameOffset)
  writeUInt32BE(record0, 0x58, titleBytes.length)
  writeUInt32BE(record0, 0x6c, 2) // firstImageIndex → record 2
  writeUInt32BE(record0, 0x80, 0)

  record0.set(titleBytes, fullNameOffset)

  // PDB: 3 records (0=metadata, 1=text, 2=image)
  const numRecords = 3
  const pdbHeaderSize = 0x4e + numRecords * 8
  const record0Offset = pdbHeaderSize
  const record1Offset = record0Offset + record0Size
  const record2Offset = record1Offset + contentBytes.length
  const totalSize = record2Offset + imageBytes.length
  const buf = new Uint8Array(totalSize)

  writeAscii(buf, 0, title.substring(0, 31), 32)
  writeUInt16BE(buf, 0x4c, numRecords)
  writeUInt32BE(buf, 0x4e, record0Offset)
  writeUInt32BE(buf, 0x4e + 4, 0)
  writeUInt32BE(buf, 0x4e + 8, record1Offset)
  writeUInt32BE(buf, 0x4e + 12, 1)
  writeUInt32BE(buf, 0x4e + 16, record2Offset)
  writeUInt32BE(buf, 0x4e + 20, 2)

  buf.set(record0, record0Offset)
  buf.set(contentBytes, record1Offset)
  buf.set(imageBytes, record2Offset)

  return buf
}

describe('extractMobiCover', () => {
  it('returns null for a buffer with no image record', () => {
    const buf = buildMobiBuffer({ title: 'No Cover' })
    expect(extractMobiCover(buf)).toBeNull()
  })

  it('returns null for a buffer that is too small', () => {
    expect(extractMobiCover(new Uint8Array(10))).toBeNull()
  })

  it('extracts a JPEG cover', () => {
    const buf = buildMobiBufferWithCover({ imageMagic: 'jpg' })
    const cover = extractMobiCover(buf)
    expect(cover).not.toBeNull()
    expect(cover!.mimeType).toBe('image/jpeg')
    expect(cover!.data.length).toBeGreaterThan(0)
    expect(cover!.data[0]).toBe(0xff)
    expect(cover!.data[1]).toBe(0xd8)
  })

  it('extracts a PNG cover', () => {
    const buf = buildMobiBufferWithCover({ imageMagic: 'png' })
    const cover = extractMobiCover(buf)
    expect(cover).not.toBeNull()
    expect(cover!.mimeType).toBe('image/png')
    expect(cover!.data[0]).toBe(0x89)
    expect(cover!.data[1]).toBe(0x50)
  })

  it('extracts a GIF cover', () => {
    const buf = buildMobiBufferWithCover({ imageMagic: 'gif' })
    const cover = extractMobiCover(buf)
    expect(cover).not.toBeNull()
    expect(cover!.mimeType).toBe('image/gif')
  })

  it('returns null when the image record has an unrecognised magic', () => {
    const buf = buildMobiBufferWithCover({ imageMagic: 'invalid' })
    expect(extractMobiCover(buf)).toBeNull()
  })
})

describe('parseMobiMetadata', () => {
  it('extracts title from the full name field', () => {
    const buf = buildMobiBuffer({ title: 'My Great Book' })
    const meta = parseMobiMetadata(buf)
    expect(meta.title).toBe('My Great Book')
  })

  it('extracts author from EXTH records', () => {
    const buf = buildMobiBuffer({ title: 'Book', author: 'Jane Doe' })
    const meta = parseMobiMetadata(buf)
    expect(meta.author).toBe('Jane Doe')
  })

  it('extracts publisher from EXTH records', () => {
    const buf = buildMobiBuffer({
      title: 'Book',
      publisher: 'Great Publisher'
    })
    const meta = parseMobiMetadata(buf)
    expect(meta.publisher).toBe('Great Publisher')
  })

  it('extracts all metadata fields together', () => {
    const buf = buildMobiBuffer({
      title: 'Full Book',
      author: 'Author A',
      publisher: 'Pub B'
    })
    const meta = parseMobiMetadata(buf)
    expect(meta.title).toBe('Full Book')
    expect(meta.author).toBe('Author A')
    expect(meta.publisher).toBe('Pub B')
  })

  it('returns null author and publisher when EXTH is absent', () => {
    const buf = buildMobiBuffer({ title: 'No EXTH' })
    const meta = parseMobiMetadata(buf)
    expect(meta.title).toBe('No EXTH')
    expect(meta.author).toBeNull()
    expect(meta.publisher).toBeNull()
  })

  it('returns nulls for a buffer that is too small', () => {
    const tinyBuf = new Uint8Array(10)
    const meta = parseMobiMetadata(tinyBuf)
    expect(meta.title).toBeNull()
    expect(meta.author).toBeNull()
    expect(meta.publisher).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// parseMobiChapters
// ---------------------------------------------------------------------------

describe('parseMobiChapters', () => {
  it('returns the full content as a single chapter when no pagebreaks', () => {
    const buf = buildMobiBuffer({ content: '<p>Single chapter</p>' })
    const chapters = parseMobiChapters(buf)
    expect(chapters).toHaveLength(1)
    expect(chapters[0]).toContain('Single chapter')
  })

  it('splits content by <mbp:pagebreak/> markers', () => {
    const content =
      '<p>Chapter 1</p><mbp:pagebreak/><p>Chapter 2</p><mbp:pagebreak/><p>Chapter 3</p>'
    const buf = buildMobiBuffer({ content })
    const chapters = parseMobiChapters(buf)
    expect(chapters).toHaveLength(3)
    expect(chapters[0]).toContain('Chapter 1')
    expect(chapters[1]).toContain('Chapter 2')
    expect(chapters[2]).toContain('Chapter 3')
  })

  it('filters out empty chapters from consecutive pagebreaks', () => {
    const content = '<p>A</p><mbp:pagebreak/><mbp:pagebreak/><p>B</p>'
    const buf = buildMobiBuffer({ content })
    const chapters = parseMobiChapters(buf)
    expect(chapters).toHaveLength(2)
    expect(chapters[0]).toContain('A')
    expect(chapters[1]).toContain('B')
  })

  it('returns empty array for buffer with too few records', () => {
    const buf = new Uint8Array(200)
    // 1 record, only the offset filled in
    writeUInt16BE(buf, 0x4c, 1)
    writeUInt32BE(buf, 0x4e, 0x56)
    const chapters = parseMobiChapters(buf)
    expect(chapters).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// parseMobiTextParagraphs (NEW — convenience for RAG chunking)
// ---------------------------------------------------------------------------

describe('parseMobiTextParagraphs', () => {
  it('returns plain-text paragraphs split per chapter', () => {
    const content =
      '<p>First chapter line one.\nLine two.</p><mbp:pagebreak/><p>Second chapter.\nMore.</p>'
    const buf = buildMobiBuffer({ content })
    const paragraphs = parseMobiTextParagraphs(buf)
    expect(paragraphs).toHaveLength(2)
    expect(paragraphs[0].join(' ')).toContain('First chapter line one')
    expect(paragraphs[0].join(' ')).toContain('Line two')
    expect(paragraphs[1].join(' ')).toContain('Second chapter')
  })

  it('filters empty lines', () => {
    const content = '<p>Hello.\n\n\nWorld.</p>'
    const buf = buildMobiBuffer({ content })
    const paragraphs = parseMobiTextParagraphs(buf)
    expect(paragraphs).toHaveLength(1)
    expect(paragraphs[0].every((p) => p.length > 0)).toBe(true)
  })
})

// ---------------------------------------------------------------------------
// palmdocDecompress
// ---------------------------------------------------------------------------

describe('palmdocDecompress', () => {
  it('passes through plain ASCII literals (0x09..0x7F)', () => {
    const input = new Uint8Array([72, 105])
    expect(palmdocDecompress(input)).toBe('Hi')
  })

  it('handles the literal-NUL marker (0x00)', () => {
    const input = new Uint8Array([0x00])
    expect(palmdocDecompress(input)).toBe('\0')
  })

  it('copies the next N bytes when a 0x01..0x08 marker appears', () => {
    const input = new Uint8Array([0x03, 97, 98, 99])
    expect(palmdocDecompress(input)).toBe('abc')
  })

  it('expands 0xC0+ as space + (byte XOR 0x80)', () => {
    const input = new Uint8Array([0xe1])
    expect(palmdocDecompress(input)).toBe(' a')
  })
})
