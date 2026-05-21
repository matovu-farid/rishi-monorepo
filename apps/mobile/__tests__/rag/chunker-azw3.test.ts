/**
 * AZW3 chunker integration test.
 *
 * AZW3 uses the same PalmDOC + EXTH layout as MOBI in 99% of files in the
 * wild — the only difference is the container (KF8 vs KF7). The chunker
 * treats `azw3` like `mobi`, dispatching to the same shared parser, and
 * returning non-empty chunks for any AZW3 that the shared parser can read.
 */

jest.mock('expo-crypto', () => ({
  randomUUID: () => 'uuid-not-expected-here',
}))

const FIXTURE_KEY = '__azw3_fixture__'
// chunker.ts imports from `expo-file-system/legacy` (SDK 54 moved the
// `readAsStringAsync` + `EncodingType` symbols there). Mock both paths
// so the chunker's call returns the per-test fixture regardless of
// which import the production code uses. The factory must be inline
// because jest.mock() is hoisted above any local `const`.
jest.mock('expo-file-system/legacy', () => ({
  readAsStringAsync: jest.fn(async () => (global as any)[FIXTURE_KEY]),
  EncodingType: { Base64: 'base64' },
}))
jest.mock('expo-file-system', () => ({
  readAsStringAsync: jest.fn(async () => (global as any)[FIXTURE_KEY]),
  EncodingType: { Base64: 'base64' },
}))

import { getChunks, resetExtractors } from '@/lib/rag/chunker'

function buildAzw3Like(content: string, title = 'AZW3 Test'): string {
  const titleBuf = Buffer.from(title, 'utf8')
  const contentBuf = Buffer.from(content, 'utf8')
  const mobiHeaderLength = 0xe8
  const fullNameOffset = 16 + mobiHeaderLength
  const record0Size = fullNameOffset + titleBuf.length
  const record0 = Buffer.alloc(record0Size)
  record0.writeUInt16BE(1, 0)
  record0.writeUInt32BE(contentBuf.length, 4)
  record0.writeUInt16BE(1, 8)
  record0.writeUInt16BE(4096, 10)
  record0.writeUInt16BE(0, 12)
  record0.write('MOBI', 16, 4, 'latin1')
  record0.writeUInt32BE(mobiHeaderLength, 0x14)
  // KF8 type marker — 8 instead of 2 — exercises the AZW3-tolerant path
  record0.writeUInt32BE(8, 0x18)
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

describe('chunker -> AZW3', () => {
  beforeEach(() => {
    resetExtractors()
    ;(global as any)[FIXTURE_KEY] = buildAzw3Like(
      '<p>AZW3 first chapter content.\nSecond line.</p><mbp:pagebreak/><p>Second chapter content.</p>'
    )
  })

  it('produces non-empty chunks for an AZW3-like PalmDOC buffer', async () => {
    const chunks = await getChunks('/fake/book.azw3', 'azw3', 'book-azw3-1')
    expect(chunks.length).toBeGreaterThan(0)
    for (const c of chunks) {
      expect(c.text.trim().length).toBeGreaterThan(0)
    }
  })

  it('assigns sequential chunkIndex starting at 0', async () => {
    const chunks = await getChunks('/fake/book.azw3', 'azw3', 'book-azw3-1')
    chunks.forEach((c, i) => expect(c.chunkIndex).toBe(i))
  })
})
