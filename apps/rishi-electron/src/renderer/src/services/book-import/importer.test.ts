import { describe, it, expect, vi } from 'vitest'
import type {
  BookImportConfig,
  BookStoreIpc,
  FileSyncIpc,
  FsIpc,
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
}): { db: BookStoreIpc; savedBooks: Book[] } {
  const savedBooks: Book[] = []
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
    savePageDataMany: vi.fn(),
    getAllPageDataByBookId: vi.fn(async () => []),
    hasSavedEpubData: vi.fn(async () => false),
    saveVectors: vi.fn()
  }
  return { db, savedBooks }
}

export function makeFileSync(opts?: {
  hashImpl?: (path: string) => Promise<string>
  uploadImpl?: () => Promise<{ r2Key: string }>
  throwOn?: 'upload' | 'updateHash'
}): FileSyncIpc {
  return {
    hashBookFile: vi.fn(async (path: string) =>
      opts?.hashImpl ? opts.hashImpl(path) : 'abc123'
    ),
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
    expect(events.map((e) => e.kind)).toEqual(['copying', 'failed'])
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
      getMobiData: vi.fn()
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
    expect(events.map((e) => e.kind)).toEqual(['copying', 'parsing', 'failed'])
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
    expect(events.map((e) => e.kind)).toEqual(['copying', 'parsing', 'saving', 'failed'])
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
    await new Promise((r) => setTimeout(r, 0))
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
    expect(events.map((e) => e.kind)).toEqual(['copying', 'parsing', 'saving', 'done'])
  })
})
