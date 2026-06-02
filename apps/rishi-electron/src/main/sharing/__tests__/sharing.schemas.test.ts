import { describe, expect, it, vi } from 'vitest'
import os from 'node:os'
import path from 'node:path'

// Need this stubbed because sharing.schemas.ts → libraryWrite.ts → electron
// (transitively). The schemas don't actually call `app` at module init.
vi.mock('electron', () => ({
  app: {
    on: () => {},
    getPath: (key: string): string => {
      if (key !== 'userData') throw new Error(`unexpected getPath(${key})`)
      return os.tmpdir()
    }
  }
}))

import {
  saveTransferredBookSchema,
  discardTransferredBookSchema,
  hasBookFileSchema,
  readBookBytesSchema,
  readReconnectSchema,
  writeReconnectSchema,
  clearReconnectSchema
} from '../sharing.schemas.js'

describe('saveTransferredBookSchema', () => {
  const valid = {
    bookId: 'b1',
    contentHash: 'a'.repeat(64),
    format: 'epub' as const,
    blob: [0, 1, 2, 255],
    receivedFromUserId: 'u1',
    receivedAt: Date.now(),
    title: 'Hello'
  }
  it('accepts a valid payload', () => {
    expect(() => saveTransferredBookSchema.parse(valid)).not.toThrow()
  })
  it('rejects empty bookId', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, bookId: '' })).toThrow()
  })
  it('rejects non-hex contentHash', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, contentHash: 'zz' })).toThrow()
  })
  it('rejects unknown format', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, format: 'mobi' })).toThrow()
  })
  it('rejects blob bytes out of range', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, blob: [0, 256] })).toThrow()
  })
  it('rejects non-integer blob bytes', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, blob: [0.5] })).toThrow()
  })
  it('rejects negative receivedAt', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, receivedAt: -1 })).toThrow()
  })
  it('rejects oversize title', () => {
    expect(() => saveTransferredBookSchema.parse({ ...valid, title: 'x'.repeat(1000) })).toThrow()
  })
})

describe('discardTransferredBookSchema', () => {
  const sharedDir = path.join(os.tmpdir(), 'shared-reading-library')
  const validPath = path.join(sharedDir, 'abc.epub')
  it('accepts a valid path inside sharedDir', () => {
    expect(() =>
      discardTransferredBookSchema.parse({ dbBookId: 1, localPath: validPath })
    ).not.toThrow()
  })
  it('rejects /etc/passwd', () => {
    expect(() =>
      discardTransferredBookSchema.parse({ dbBookId: 1, localPath: '/etc/passwd' })
    ).toThrow(/outside|shared-reading-library/i)
  })
  it('rejects a sibling-traversal path', () => {
    const evil = path.join(sharedDir, '..', '..', 'etc', 'passwd')
    expect(() => discardTransferredBookSchema.parse({ dbBookId: 1, localPath: evil })).toThrow(
      /outside|shared-reading-library/i
    )
  })
  it('rejects non-positive dbBookId', () => {
    expect(() =>
      discardTransferredBookSchema.parse({ dbBookId: 0, localPath: validPath })
    ).toThrow()
  })
})

describe('hasBookFileSchema', () => {
  it('accepts valid', () => {
    expect(() => hasBookFileSchema.parse({ contentHash: 'a'.repeat(64) })).not.toThrow()
  })
  it('rejects non-hex', () => {
    expect(() => hasBookFileSchema.parse({ contentHash: 'zz' })).toThrow()
  })
})

describe('readBookBytesSchema', () => {
  it('accepts valid', () => {
    expect(() =>
      readBookBytesSchema.parse({ bookId: 'b1', contentHash: 'b'.repeat(64) })
    ).not.toThrow()
  })
  it('rejects empty bookId', () => {
    expect(() => readBookBytesSchema.parse({ bookId: '', contentHash: 'b'.repeat(64) })).toThrow()
  })
})

describe('readReconnectSchema', () => {
  it('accepts valid', () => {
    expect(() => readReconnectSchema.parse({ userId: 'u1' })).not.toThrow()
  })
  it('rejects empty userId', () => {
    expect(() => readReconnectSchema.parse({ userId: '' })).toThrow()
  })
})

describe('writeReconnectSchema', () => {
  const valid = {
    userId: 'u1',
    sessionId: 's1',
    reconnectToken: 'tok',
    wsUrl: 'wss://x.example/y',
    reservedUntil: Date.now() + 60_000
  }
  it('accepts valid', () => {
    expect(() => writeReconnectSchema.parse(valid)).not.toThrow()
  })
  it('rejects non-url wsUrl', () => {
    expect(() => writeReconnectSchema.parse({ ...valid, wsUrl: 'not-a-url' })).toThrow()
  })
  it('rejects empty fields', () => {
    expect(() => writeReconnectSchema.parse({ ...valid, sessionId: '' })).toThrow()
  })
})

describe('clearReconnectSchema', () => {
  it('accepts valid', () => {
    expect(() => clearReconnectSchema.parse({ userId: 'u1' })).not.toThrow()
  })
  it('rejects empty userId', () => {
    expect(() => clearReconnectSchema.parse({ userId: '' })).toThrow()
  })
})
