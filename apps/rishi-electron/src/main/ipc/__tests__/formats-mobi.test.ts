import { describe, it, expect } from 'vitest'
import { stripHtmlTags, parseMobiChapters, parseMobiMetadata } from '../formats.js'

// ---------------------------------------------------------------------------
// Helper: build a minimal MOBI file buffer for testing.
//
// A MOBI file is a PDB container with:
//   - PDB header (78 bytes + 8 bytes per record entry)
//   - Record 0: PalmDOC header (16 bytes) + MOBI header + optional EXTH + full name
//   - Records 1..N: text content records (uncompressed, compression=1)
// ---------------------------------------------------------------------------

function buildMobiBuffer(options: {
  title?: string
  author?: string
  publisher?: string
  content?: string
  compression?: number
}): Buffer {
  const title = options.title ?? 'Test Book'
  const author = options.author ?? ''
  const publisher = options.publisher ?? ''
  const content = options.content ?? '<p>Hello world</p>'
  const compression = options.compression ?? 1 // 1 = no compression

  const hasExth = author.length > 0 || publisher.length > 0

  // We'll build record 0 and record 1 (text content), then construct PDB header.

  // --- Build EXTH records if needed ---
  let exthBlock = Buffer.alloc(0)
  if (hasExth) {
    const exthRecords: Buffer[] = []

    if (author.length > 0) {
      const authorBuf = Buffer.from(author, 'utf8')
      const rec = Buffer.alloc(8 + authorBuf.length)
      rec.writeUInt32BE(100, 0) // type: author
      rec.writeUInt32BE(8 + authorBuf.length, 4) // length
      authorBuf.copy(rec, 8)
      exthRecords.push(rec)
    }

    if (publisher.length > 0) {
      const pubBuf = Buffer.from(publisher, 'utf8')
      const rec = Buffer.alloc(8 + pubBuf.length)
      rec.writeUInt32BE(101, 0) // type: publisher
      rec.writeUInt32BE(8 + pubBuf.length, 4) // length
      pubBuf.copy(rec, 8)
      exthRecords.push(rec)
    }

    // EXTH header: "EXTH" + headerLength(4) + recordCount(4) + records
    const recordsData = Buffer.concat(exthRecords)
    exthBlock = Buffer.alloc(12 + recordsData.length)
    exthBlock.write('EXTH', 0, 4, 'latin1')
    exthBlock.writeUInt32BE(12 + recordsData.length, 4) // total EXTH length
    exthBlock.writeUInt32BE(exthRecords.length, 8) // record count
    recordsData.copy(exthBlock, 12)
  }

  // --- Build MOBI header ---
  // We need headerLength to be at least 0xE8 for the full name offset to be valid.
  // MOBI header starts at offset 16 in record 0. headerLength includes from offset 16.
  const mobiHeaderLength = 0xe8 // standard MOBI header length (232 bytes)

  // Full name goes after MOBI header + EXTH
  const fullNameOffset = 16 + mobiHeaderLength + exthBlock.length
  const titleBuf = Buffer.from(title, 'utf8')

  // Record 0 total size
  const record0Size = fullNameOffset + titleBuf.length
  const record0 = Buffer.alloc(record0Size)

  // PalmDOC header (first 16 bytes of record 0)
  record0.writeUInt16BE(compression, 0) // compression
  // 2 bytes unused
  const contentBuf = Buffer.from(content, 'utf8')
  record0.writeUInt32BE(contentBuf.length, 4) // text_length
  record0.writeUInt16BE(1, 8) // textRecordCount (1 text record)
  record0.writeUInt16BE(4096, 10) // recordSize
  record0.writeUInt16BE(0, 12) // encryption (none)

  // MOBI header starts at offset 16
  // "MOBI" magic at offset 16
  record0.write('MOBI', 16, 4, 'latin1')
  record0.writeUInt32BE(mobiHeaderLength, 0x14) // headerLength
  // mobiType at offset 0x18
  record0.writeUInt32BE(2, 0x18) // MOBI type (2 = Mobipocket book)
  // encoding at offset 0x1C
  record0.writeUInt32BE(65001, 0x1c) // UTF-8

  // firstNonBookIndex at offset 0x50
  record0.writeUInt32BE(2, 0x50) // after text record
  // fullNameOffset at offset 0x54
  record0.writeUInt32BE(fullNameOffset, 0x54)
  // fullNameLength at offset 0x58
  record0.writeUInt32BE(titleBuf.length, 0x58)

  // firstImageIndex at offset 0x6C
  record0.writeUInt32BE(0, 0x6c) // no images

  // exthFlags at offset 0x80
  record0.writeUInt32BE(hasExth ? 0x40 : 0x00, 0x80)

  // flags at offset 0xF2 — set to 0 for simplicity (no trailers/multibyte)
  if (record0.length > 0xf2 + 2) {
    record0.writeUInt16BE(0, 0xf2)
  }

  // Copy EXTH block
  if (exthBlock.length > 0) {
    exthBlock.copy(record0, 16 + mobiHeaderLength)
  }

  // Copy title
  titleBuf.copy(record0, fullNameOffset)

  // --- Build PDB header ---
  const numRecords = 2 // record 0 + 1 text record
  const pdbHeaderSize = 0x4e + numRecords * 8
  const record0Offset = pdbHeaderSize
  const record1Offset = record0Offset + record0Size

  const totalSize = record1Offset + contentBuf.length
  const buf = Buffer.alloc(totalSize)

  // PDB name (first 32 bytes)
  buf.write(title.substring(0, 31), 0, 32, 'latin1')

  // Record count at offset 0x4C
  buf.writeUInt16BE(numRecords, 0x4c)

  // Record list at offset 0x4E
  // Record 0
  buf.writeUInt32BE(record0Offset, 0x4e)
  buf.writeUInt32BE(0, 0x4e + 4) // id

  // Record 1 (text content)
  buf.writeUInt32BE(record1Offset, 0x4e + 8)
  buf.writeUInt32BE(1, 0x4e + 12) // id

  // Copy record 0
  record0.copy(buf, record0Offset)

  // Copy text content as record 1
  contentBuf.copy(buf, record1Offset)

  return buf
}

// ---------------------------------------------------------------------------
// stripHtmlTags tests
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
// parseMobiMetadata tests
// ---------------------------------------------------------------------------

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
    const tinyBuf = Buffer.alloc(10)
    const meta = parseMobiMetadata(tinyBuf)
    expect(meta.title).toBeNull()
    expect(meta.author).toBeNull()
    expect(meta.publisher).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// parseMobiChapters tests
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
    // A buffer with only 1 PDB record (no content records)
    const buf = Buffer.alloc(200)
    buf.writeUInt16BE(1, 0x4c) // 1 record
    buf.writeUInt32BE(0x56, 0x4e) // record 0 offset
    const chapters = parseMobiChapters(buf)
    expect(chapters).toEqual([])
  })
})
