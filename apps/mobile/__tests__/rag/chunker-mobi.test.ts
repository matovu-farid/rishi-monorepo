/**
 * MOBI chunker integration test.
 *
 * Builds a tiny in-memory MOBI buffer (PalmDOC, uncompressed) and asserts
 * the mobile chunker walks the @rishi/shared/formats/mobi parser end-to-end
 * to produce non-empty chunks with stable IDs.
 */

jest.mock('expo-crypto', () => ({
  randomUUID: () => 'uuid-not-expected-here',
}))

// FileSystem returns the same fixture every time
const FIXTURE_KEY = '__mobi_fixture__'
jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn(async () => (global as any)[FIXTURE_KEY]),
  EncodingType: { Base64: 'base64' },
}))

import { getChunks, resetExtractors } from '@/lib/rag/chunker'

// Helpers to build a minimal MOBI buffer (uncompressed) — mirrors the shared
// fixture builder. We use Buffer here because we're in Node under jest; the
// parser still receives a Uint8Array.
function buildMobi(content: string, title = 'Tiny'): string {
  const titleBuf = Buffer.from(title, 'utf8')
  const contentBuf = Buffer.from(content, 'utf8')
  const mobiHeaderLength = 0xe8
  const fullNameOffset = 16 + mobiHeaderLength
  const record0Size = fullNameOffset + titleBuf.length
  const record0 = Buffer.alloc(record0Size)
  record0.writeUInt16BE(1, 0) // compression = none
  record0.writeUInt32BE(contentBuf.length, 4)
  record0.writeUInt16BE(1, 8) // textRecordCount
  record0.writeUInt16BE(4096, 10)
  record0.writeUInt16BE(0, 12)
  record0.write('MOBI', 16, 4, 'latin1')
  record0.writeUInt32BE(mobiHeaderLength, 0x14)
  record0.writeUInt32BE(2, 0x18)
  record0.writeUInt32BE(65001, 0x1c)
  record0.writeUInt32BE(2, 0x50)
  record0.writeUInt32BE(fullNameOffset, 0x54)
  record0.writeUInt32BE(titleBuf.length, 0x58)
  record0.writeUInt32BE(0, 0x6c)
  record0.writeUInt32BE(0, 0x80)
  if (record0.length > 0xf2 + 2) record0.writeUInt16BE(0, 0xf2)
  titleBuf.copy(record0, fullNameOffset)

  const numRecords = 2
  const pdbHeaderSize = 0x4e + numRecords * 8
  const record0Offset = pdbHeaderSize
  const record1Offset = record0Offset + record0Size
  const totalSize = record1Offset + contentBuf.length
  const buf = Buffer.alloc(totalSize)
  buf.write(title.substring(0, 31), 0, 32, 'latin1')
  buf.writeUInt16BE(numRecords, 0x4c)
  buf.writeUInt32BE(record0Offset, 0x4e)
  buf.writeUInt32BE(0, 0x4e + 4)
  buf.writeUInt32BE(record1Offset, 0x4e + 8)
  buf.writeUInt32BE(1, 0x4e + 12)
  record0.copy(buf, record0Offset)
  contentBuf.copy(buf, record1Offset)
  return buf.toString('base64')
}

describe('chunker -> MOBI', () => {
  beforeEach(() => {
    resetExtractors()
    ;(global as any)[FIXTURE_KEY] = buildMobi(
      '<p>Chapter one starts here.\nLine two.</p><mbp:pagebreak/><p>Chapter two begins.\nMore content.</p>'
    )
  })

  it('produces non-empty chunks for a real PalmDOC buffer', async () => {
    const chunks = await getChunks('/fake/book.mobi', 'mobi', 'book-mobi-1')
    expect(chunks.length).toBeGreaterThan(0)
    for (const c of chunks) {
      expect(c.text.trim().length).toBeGreaterThan(0)
    }
  })

  it('attaches chapter labels (per pagebreak split)', async () => {
    const chunks = await getChunks('/fake/book.mobi', 'mobi', 'book-mobi-1')
    const chapters = new Set(chunks.map((c) => c.chapter))
    // Mobi chapter labels are not h1/h2-derived; we use a numeric chapter index.
    // At minimum, multiple distinct chapters should be represented.
    expect(chapters.size).toBeGreaterThanOrEqual(2)
  })

  it('produces stable IDs across runs', async () => {
    const a = await getChunks('/fake/book.mobi', 'mobi', 'book-mobi-stable')
    const b = await getChunks('/fake/book.mobi', 'mobi', 'book-mobi-stable')
    expect(a.map((c) => c.id)).toEqual(b.map((c) => c.id))
  })
})
