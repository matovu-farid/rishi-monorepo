import { describe, it, expect, vi } from 'vitest'
import type {
  BookImportConfig,
  BookStoreIpc,
  FileSyncIpc,
  FsIpc,
  ImportFailure,
  ImportProgressEvent
} from './types'
import type { Book } from '@/lib/api'
import { makeFormats } from './dispatch.test'
import { runImport } from './importer'

export function makeFs(opts?: {
  copyImpl?: (path: string) => Promise<string>
  removeImpl?: (path: string) => Promise<void>
}): {
  fs: FsIpc
  removeCalls: string[]
  copyCalls: string[]
} {
  const removeCalls: string[] = []
  const copyCalls: string[] = []
  const fs: FsIpc = {
    copyBookToAppData: vi.fn(async (path: string) => {
      copyCalls.push(path)
      if (opts?.copyImpl) return opts.copyImpl(path)
      const filename = path.split('/').pop() ?? 'book'
      return `/userData/${filename}`
    }),
    removeFile: vi.fn(async (path: string) => {
      removeCalls.push(path)
      if (opts?.removeImpl) return opts.removeImpl(path)
    }),
    getAppDataPath: vi.fn(async () => '/userData')
  }
  return { fs, removeCalls, copyCalls }
}

export function makeDbForImport(opts?: {
  savedBook?: Book
  failOn?: 'saveBook'
  findBookByHashImpl?: (hash: string) => Promise<Book | null>
}): {
  db: BookStoreIpc
  savedBooks: Book[]
  findHashCalls: string[]
} {
  const savedBooks: Book[] = []
  const findHashCalls: string[] = []
  const fallback: Book = {
    id: 42,
    kind: 'epub',
    cover: [],
    title: 'Title',
    author: 'Author',
    publisher: 'Pub',
    filepath: '/userData/book.epub',
    location: '1',
    coverKind: 'image/png',
    version: 0,
    format: 'epub',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0
  }
  const db: BookStoreIpc = {
    saveBook: vi.fn(async (b) => {
      if (opts?.failOn === 'saveBook') throw new Error('saveBook failed')
      const out = { ...fallback, ...b, id: opts?.savedBook?.id ?? fallback.id } as Book
      savedBooks.push(out)
      return out
    }),
    findBookByHash: vi.fn(async (hash) => {
      findHashCalls.push(hash)
      return opts?.findBookByHashImpl ? opts.findBookByHashImpl(hash) : null
    }),
    savePageDataMany: vi.fn(),
    getAllPageDataByBookId: vi.fn(async () => []),
    hasSavedEpubData: vi.fn(async () => false),
    saveVectors: vi.fn()
  }
  return { db, savedBooks, findHashCalls }
}

export function makeFileSync(opts?: {
  hashImpl?: (path: string) => Promise<string>
  uploadImpl?: () => Promise<{ r2Key: string }>
  throwOn?: 'upload' | 'updateHash'
}): FileSyncIpc {
  return {
    hashBookFile: vi.fn(async (path: string) => (opts?.hashImpl ? opts.hashImpl(path) : 'abc123')),
    uploadBookFile: vi.fn(async () => {
      if (opts?.throwOn === 'upload') throw new Error('upload failed')
      return opts?.uploadImpl ? opts.uploadImpl() : { r2Key: 'r2/abc' }
    }),
    booksUpdateFileHash: vi.fn(async () => {
      if (opts?.throwOn === 'updateHash') throw new Error('updateHash failed')
    })
  }
}

export const baseConfig: BookImportConfig = {
  copyTimeoutMs: 5_000,
  hashTimeoutMs: 5_000,
  parseTimeoutMs: 5_000,
  saveTimeoutMs: 5_000,
  embedBatchSize: 2
}

describe('runImport — unsupported extension', () => {
  it('returns stage: unsupported and never touches formats / DB', async () => {
    const { formats, calls } = makeFormats()
    const { fs, copyCalls, removeCalls } = makeFs()
    const { db, savedBooks } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/note.txt',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.stage).toBe('unsupported')
      expect(result.error).toMatch(/Unsupported format: \.txt/)
    }
    // Copy DID run (we copy before dispatch in pipeline order); format calls did not.
    expect(copyCalls).toEqual(['/Downloads/note.txt'])
    expect(calls).toEqual([])
    expect(savedBooks).toEqual([])
    // No rollback for unsupported (the file is a normal copy; caller may delete).
    expect(removeCalls).toEqual([])
    // Hash + dedup runs after copy (before the extension check), so `hashing`
    // is emitted before the unsupported failure.
    expect(events.map((e) => e.kind)).toEqual(['copying', 'hashing', 'failed'])
  })
})

describe('runImport — copy failure', () => {
  it('returns stage: copy and never parses', async () => {
    const { formats, calls } = makeFormats()
    const { fs, removeCalls } = makeFs({
      copyImpl: async () => {
        throw new Error('disk full')
      }
    })
    const { db } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/book.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.stage).toBe('copy')
    expect(calls).toEqual([])
    expect(removeCalls).toEqual([])
    expect(events.map((e) => e.kind)).toEqual(['copying', 'failed'])
  })
})

describe('runImport — parse failure rolls back the copy', () => {
  it('removes the copied file and returns stage: parse', async () => {
    const failingFormats = {
      getBookData: vi.fn(async () => {
        throw new Error('bad zip')
      }),
      getPdfData: vi.fn(),
      getMobiData: vi.fn(),
      getAzw3Data: vi.fn()
    }
    const { fs, removeCalls } = makeFs()
    const { db, savedBooks } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats: failingFormats, fs, db, fileSync, config: baseConfig },
      '/Downloads/broken.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.stage).toBe('parse')
    expect(removeCalls).toEqual(['/userData/broken.epub'])
    expect(savedBooks).toEqual([])
    expect(events.map((e) => e.kind)).toEqual(['copying', 'hashing', 'parsing', 'failed'])
  })
})

describe('runImport — save failure does NOT roll back copy', () => {
  it('returns stage: save and leaves the copied file on disk', async () => {
    const { formats } = makeFormats()
    const { fs, removeCalls } = makeFs()
    const { db } = makeDbForImport({ failOn: 'saveBook' })
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/book.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.stage).toBe('save')
    expect(removeCalls).toEqual([])
    expect(events.map((e) => e.kind)).toEqual([
      'copying',
      'hashing',
      'parsing',
      'saving',
      'failed'
    ])
  })
})

describe('runImport — upload failure does NOT affect result', () => {
  it('returns ok and emits upload-failed asynchronously', async () => {
    const { formats } = makeFormats()
    const { fs } = makeFs()
    const { db } = makeDbForImport()
    const fileSync = makeFileSync({ throwOn: 'upload' })
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/book.epub',
      (e) => events.push(e)
    )

    expect(result.ok).toBe(true)
    // `done` fires synchronously after save; `upload-failed` arrives on the next tick.
    await new Promise((r) => {
      setTimeout(r, 0)
    })
    const kinds = events.map((e) => e.kind)
    expect(kinds).toContain('upload-started')
    expect(kinds).toContain('upload-failed')
    // `done` must come before `upload-failed`.
    expect(kinds.indexOf('done')).toBeLessThan(kinds.indexOf('upload-failed'))
  })
})

describe('runImport — happy path EPUB', () => {
  it('returns { ok: true } and emits copying -> parsing -> saving -> done', async () => {
    const { formats } = makeFormats()
    const { fs, copyCalls } = makeFs()
    const { db, savedBooks } = makeDbForImport()
    const fileSync = makeFileSync()
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats, fs, db, fileSync, config: baseConfig },
      '/Downloads/sample.epub',
      (e) => events.push(e)
    )

    expect(result).toEqual({
      ok: true,
      bookId: 42,
      filePath: '/Downloads/sample.epub',
      format: 'epub'
    })
    expect(copyCalls).toEqual(['/Downloads/sample.epub'])
    expect(savedBooks).toHaveLength(1)
    expect(savedBooks[0].filepath).toBe('/userData/sample.epub')
    expect(events.map((e) => e.kind)).toEqual([
      'copying',
      'hashing',
      'parsing',
      'saving',
      'done'
    ])
  })
})

describe('runImport — hash + dedup stage', () => {
  it('returns stage: duplicate and rolls back the copy when the hash matches an existing book', async () => {
    const existing: Book = {
      id: 7,
      kind: 'epub',
      cover: [],
      title: 'Already here',
      author: '',
      publisher: '',
      filepath: '/userData/already.epub',
      location: '1',
      coverKind: 'image/png',
      version: 0,
      format: 'epub',
      syncVersion: 0,
      isDirty: 0,
      isDeleted: 0
    }
    const { db, findHashCalls } = makeDbForImport({
      findBookByHashImpl: async () => existing
    })
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({ hashImpl: async () => 'dupe-hash' })
    const events: ImportProgressEvent[] = []

    const result = await runImport(
      { formats: makeFormats().formats, fs, db, fileSync, config: baseConfig },
      '/external/dupe.epub',
      (e) => events.push(e)
    )

    expect(result).toEqual({
      ok: false,
      filePath: '/external/dupe.epub',
      stage: 'duplicate',
      error: expect.stringMatching(/already in library/i)
    })
    expect(findHashCalls).toEqual(['dupe-hash'])
    // The copied file under /userData was rolled back.
    expect(removeCalls).toEqual(['/userData/dupe.epub'])
    // saveBook never ran.
    expect(db.saveBook).not.toHaveBeenCalled()
    // We emitted a hashing event and a failed event.
    expect(events.map((e) => e.kind)).toEqual(['copying', 'hashing', 'failed'])
  })

  it('passes the computed file hash to saveBook when no duplicate exists', async () => {
    const { db, savedBooks } = makeDbForImport()
    const { fs } = makeFs()
    const fileSync = makeFileSync({ hashImpl: async () => 'new-hash-xyz' })

    const result = await runImport(
      { formats: makeFormats().formats, fs, db, fileSync, config: baseConfig },
      '/external/new.epub',
      () => {}
    )

    expect(result.ok).toBe(true)
    expect(savedBooks).toHaveLength(1)
    expect(savedBooks[0].fileHash).toBe('new-hash-xyz')
  })

  it('returns stage: hash and rolls back the copy when hashing throws', async () => {
    const { db } = makeDbForImport()
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({
      hashImpl: async () => {
        throw new Error('disk read failed')
      }
    })

    const result = await runImport(
      { formats: makeFormats().formats, fs, db, fileSync, config: baseConfig },
      '/external/broken.epub',
      () => {}
    )

    expect(result).toEqual({
      ok: false,
      filePath: '/external/broken.epub',
      stage: 'hash',
      error: expect.stringMatching(/disk read failed|hash/i)
    })
    expect(removeCalls).toEqual(['/userData/broken.epub'])
    expect(db.findBookByHash).not.toHaveBeenCalled()
    expect(db.saveBook).not.toHaveBeenCalled()
  })

  it('returns stage: hash when hashBookFile exceeds hashTimeoutMs', async () => {
    const { db } = makeDbForImport()
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({
      hashImpl: () => new Promise<string>(() => {}) // never resolves
    })
    const tightConfig: BookImportConfig = { ...baseConfig, hashTimeoutMs: 10 }

    const result = await runImport(
      { formats: makeFormats().formats, fs, db, fileSync, config: tightConfig },
      '/external/slow.epub',
      () => {}
    )

    expect(result.ok).toBe(false)
    expect((result as ImportFailure).stage).toBe('hash')
    expect((result as ImportFailure).error).toMatch(/timed out|hash/i)
    expect(removeCalls).toEqual(['/userData/slow.epub'])
  })

  it('returns stage: hash and rolls back the copy when the dedup lookup throws', async () => {
    const { db } = makeDbForImport({
      findBookByHashImpl: async () => {
        throw new Error('db unavailable')
      }
    })
    const { fs, removeCalls } = makeFs()
    const fileSync = makeFileSync({ hashImpl: async () => 'ok-hash' })

    const result = await runImport(
      { formats: makeFormats().formats, fs, db, fileSync, config: baseConfig },
      '/external/x.epub',
      () => {}
    )

    expect(result.ok).toBe(false)
    expect((result as ImportFailure).stage).toBe('hash')
    expect((result as ImportFailure).error).toMatch(/db unavailable|Checking library/i)
    expect(removeCalls).toEqual(['/userData/x.epub'])
    expect(db.saveBook).not.toHaveBeenCalled()
  })
})
