import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { promises as fs } from 'node:fs'
import { createHash } from 'node:crypto'
import os from 'node:os'
import path from 'node:path'

// `electron` is required transitively (queries.ts → index.ts → app.on(...))
// even though the unit test never touches the DB. Stub the surface so the
// import chain doesn't crash in plain Node.
vi.mock('electron', () => ({
  app: {
    on: () => {},
    getPath: (key: string): string => {
      if (key !== 'userData') throw new Error(`unexpected getPath(${key})`)
      return os.tmpdir()
    }
  }
}))

import { _readBookBytesWithDeps } from '../libraryRead.js'
import type { Book } from '../../database/queries.js'

function sha256Hex(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex')
}

function fakeBook(overrides: Partial<Book>): Book {
  return {
    id: 1,
    kind: 'pdf',
    cover: [],
    title: 'Test Book',
    author: '',
    publisher: '',
    filepath: '',
    location: '',
    coverKind: 'png',
    version: 1,
    syncId: null,
    fileHash: null,
    fileR2Key: null,
    coverR2Key: null,
    fileSize: 0,
    format: 'pdf',
    currentCfi: null,
    currentPage: null,
    userId: null,
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
    lastParagraph: null,
    ...overrides
  }
}

describe('readBookBytes', () => {
  let tmpDir = ''
  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'rishi-readbook-'))
  })
  afterEach(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true })
  })

  it('reads bytes and returns format when hash matches the file', async () => {
    const bytes = Buffer.from('hello world pdf')
    const hash = sha256Hex(bytes)
    const filepath = path.join(tmpDir, 'book.pdf')
    await fs.writeFile(filepath, bytes)

    const out = await _readBookBytesWithDeps(
      { bookId: 'b1', contentHash: hash },
      { findByHash: () => fakeBook({ filepath, format: 'pdf' }) }
    )
    expect(out.format).toBe('pdf')
    expect(Array.from(out.bytes)).toEqual(Array.from(bytes))
  })

  it('throws when no book matches the contentHash', async () => {
    await expect(
      _readBookBytesWithDeps(
        { bookId: 'b1', contentHash: 'missing' },
        { findByHash: () => undefined }
      )
    ).rejects.toThrow(/not_found/)
  })

  it('throws when the file is missing on disk', async () => {
    await expect(
      _readBookBytesWithDeps(
        { bookId: 'b1', contentHash: 'abc' },
        { findByHash: () => fakeBook({ filepath: path.join(tmpDir, 'nope.pdf') }) }
      )
    ).rejects.toThrow()
  })

  it('throws when the on-disk hash does not match contentHash', async () => {
    const bytes = Buffer.from('real bytes')
    const filepath = path.join(tmpDir, 'book.pdf')
    await fs.writeFile(filepath, bytes)
    await expect(
      _readBookBytesWithDeps(
        { bookId: 'b1', contentHash: 'wrong_hash' },
        { findByHash: () => fakeBook({ filepath, format: 'pdf' }) }
      )
    ).rejects.toThrow(/hash_mismatch/)
  })

  it('refuses unsupported formats', async () => {
    const bytes = Buffer.from('x')
    const hash = sha256Hex(bytes)
    const filepath = path.join(tmpDir, 'x.txt')
    await fs.writeFile(filepath, bytes)
    await expect(
      _readBookBytesWithDeps(
        { bookId: 'b1', contentHash: hash },
        { findByHash: () => fakeBook({ filepath, format: 'txt' as unknown as 'pdf' }) }
      )
    ).rejects.toThrow(/unsupported_format/)
  })
})
