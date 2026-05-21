/**
 * Mobile file-import.ts tests. The actual file-import functions call into
 * the shared book-import service through mobile-specific port adapters.
 * Native modules (expo-file-system, expo-crypto, drizzle, react-native-mmkv,
 * react-native-executorch) are stubbed.
 */

// ────────────────────────────────────────────────────────────────────────────
// Test fakes for native modules + storage
// ────────────────────────────────────────────────────────────────────────────

type FakeFile = {
  uri: string;
  exists: boolean;
  copy: jest.Mock;
  write: jest.Mock;
  bytes: jest.Mock;
  base64: jest.Mock;
  delete: jest.Mock;
}

const fakeFiles = new Map<string, FakeFile>()
let pickFileResult: { uri: string } | { uri: string }[] | null = null

function makeFakeFile(uri: string, opts?: { bytes?: Uint8Array; exists?: boolean }): FakeFile {
  const file: FakeFile = {
    uri,
    exists: opts?.exists ?? true,
    copy: jest.fn((dest: FakeFile) => {
      dest.exists = true
    }),
    write: jest.fn(),
    bytes: jest.fn(async () => opts?.bytes ?? new Uint8Array([1, 2, 3])),
    base64: jest.fn(async () => 'dGVzdA=='),
    delete: jest.fn(() => {
      file.exists = false
    }),
  }
  return file
}

jest.mock('expo-file-system', () => {
  const FileCtor = jest.fn().mockImplementation((arg1: any, arg2?: string) => {
    // Two overloads: new File(uri) | new File(dir, name)
    let uri: string
    if (arg2 === undefined) {
      uri = typeof arg1 === 'string' ? arg1 : arg1.uri ?? ''
    } else {
      uri = (typeof arg1 === 'string' ? arg1 : arg1.uri) + '/' + arg2
    }
    if (!fakeFiles.has(uri)) {
      fakeFiles.set(uri, makeFakeFile(uri))
    }
    return fakeFiles.get(uri)!
  }) as any
  ;(FileCtor as any).pickFileAsync = jest.fn(async () => pickFileResult)

  const DirectoryCtor = jest.fn().mockImplementation((arg1: any, name?: string) => {
    const base = typeof arg1 === 'string' ? arg1 : arg1.uri ?? '/root'
    const uri = name ? `${base}/${name}` : base
    return {
      uri,
      exists: true,
      create: jest.fn(),
    }
  })

  return {
    File: FileCtor,
    Directory: DirectoryCtor,
    Paths: { document: '/docs' },
    readAsStringAsync: jest.fn(async () => ''),
    EncodingType: { Base64: 'base64' },
  }
})

jest.mock('expo-crypto', () => ({
  randomUUID: () => 'uuid-test-fixed',
  digestStringAsync: jest.fn(async () => 'fake-hash-abc'),
  CryptoDigestAlgorithm: { SHA256: 'SHA-256' },
}))

// Drizzle DB — collect insert + update calls.
const dbRecord = {
  insertCalls: [] as Array<{ table: string; values: any }>,
  updateCalls: [] as Array<{ table: string; values: any; where: any }>,
}

function makeDbStub() {
  const insertChain = {
    values: (values: any) => ({ run: () => dbRecord.insertCalls.push({ table: 'books', values }) }),
  }
  const updateChain = (values: any) => ({
    set: (v: any) => ({ where: (w: any) => ({ run: () => dbRecord.updateCalls.push({ table: 'books', values: v, where: w }) }) }),
  })
  return {
    insert: (_table: any) => insertChain,
    update: (_table: any) => ({
      set: (v: any) => ({
        where: (w: any) => ({
          run: () => dbRecord.updateCalls.push({ table: 'books', values: v, where: w }),
        }),
      }),
    }),
    select: () => ({
      from: () => ({
        where: () => ({
          get: () => null,
          all: () => [],
        }),
      }),
    }),
  }
}

jest.mock('@/lib/db', () => ({
  db: makeDbStub(),
  rawDb: {
    execSync: jest.fn(),
    runSync: jest.fn(),
    getAllSync: jest.fn(() => []),
    loadExtensionSync: jest.fn(),
  },
}))

// Sync triggers — no-op.
jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: jest.fn(),
}))

// R2 upload helpers.
const uploadCalls: any[] = []
let uploadShouldFail = false
jest.mock('@/lib/sync/file-sync', () => ({
  hashBookFile: jest.fn(async () => 'fake-hash'),
  uploadBookFile: jest.fn(async (path: string, hash: string, format: string) => {
    uploadCalls.push({ path, hash, format })
    if (uploadShouldFail) throw new Error('upload failed')
    return { r2Key: `r2/${format}/${hash}` }
  }),
}))

// Chunker / embedder / vector store. We control return values per-test.
const chunkerCalls: any[] = []
let chunkerReturn: any[] = []
jest.mock('@/lib/rag/chunker', () => ({
  getChunks: jest.fn(async (path: string, format: string, bookId: string) => {
    chunkerCalls.push({ path, format, bookId })
    return chunkerReturn
  }),
}))

let embeddingReady = true
let embedThrows = false
jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: jest.fn(async (texts: string[]) => {
    if (embedThrows) throw new Error('embed failed')
    return texts.map(() => [0.1, 0.2, 0.3])
  }),
  isEmbeddingReady: jest.fn(() => embeddingReady),
}))

jest.mock('@/lib/rag/server-fallback', () => ({
  embedTextsOnServer: jest.fn(async (texts: string[]) => texts.map(() => [0.5, 0.5, 0.5])),
}))

const vectorStoreCalls = {
  insertCalls: [] as any[],
  embedded: new Set<string>(),
}
jest.mock('@/lib/rag/vector-store', () => ({
  insertChunkWithVector: jest.fn((id, bookId, idx, text, chapter, embedding) => {
    vectorStoreCalls.insertCalls.push({ id, bookId, idx, text, chapter, embedding })
    vectorStoreCalls.embedded.add(bookId)
  }),
  isBookEmbedded: jest.fn((bookId: string) => vectorStoreCalls.embedded.has(bookId)),
  deleteBookChunks: jest.fn(),
}))

// Book-storage triggers (lib/book-storage uses it for sync). Not used here.
jest.mock('@/lib/book-storage', () => ({
  insertBook: jest.fn(),
}))

// EPUB cover extraction — we control the result per-test.
let coverReturn: { mimeType: string; data: Uint8Array } | null = null
jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: jest.fn(async () => coverReturn),
}))

// ────────────────────────────────────────────────────────────────────────────
// Imports (after mocks)
// ────────────────────────────────────────────────────────────────────────────

import {
  importEpubFile,
  importPdfFile,
  importMobiFile,
  importDjvuFile,
} from '@/lib/file-import'
import * as fileSync from '@/lib/sync/file-sync'
import { extractEpubCover } from '@rishi/shared/formats/epub-cover'

function resetState() {
  fakeFiles.clear()
  dbRecord.insertCalls.length = 0
  dbRecord.updateCalls.length = 0
  uploadCalls.length = 0
  uploadShouldFail = false
  chunkerCalls.length = 0
  chunkerReturn = []
  embeddingReady = true
  embedThrows = false
  vectorStoreCalls.insertCalls.length = 0
  vectorStoreCalls.embedded.clear()
  coverReturn = null
  ;(extractEpubCover as jest.Mock).mockClear()
  jest.clearAllMocks()
  ;(fileSync.hashBookFile as jest.Mock).mockImplementation(async () => 'fake-hash')
  ;(fileSync.uploadBookFile as jest.Mock).mockImplementation(async (path: string, hash: string, format: string) => {
    uploadCalls.push({ path, hash, format })
    if (uploadShouldFail) throw new Error('upload failed')
    return { r2Key: `r2/${format}/${hash}` }
  })
}

// Helper: wait long enough for setTimeout(0) chains (cover + upload run on a
// later tick) to complete.
async function flushAsync(ticks = 5) {
  for (let i = 0; i < ticks; i++) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

describe('file-import — EPUB happy path', () => {
  beforeEach(() => resetState())

  it('inserts a book row, extracts cover, uploads to R2, and indexes chunks', async () => {
    pickFileResult = { uri: '/Downloads/sample.epub' }
    coverReturn = { mimeType: 'image/png', data: new Uint8Array([10, 20, 30]) }
    chunkerReturn = [
      { id: 'c1', bookId: 'ignored', chunkIndex: 0, text: 'Hello world.', chapter: 'Ch 1', createdAt: 1 },
      { id: 'c2', bookId: 'ignored', chunkIndex: 1, text: 'Second chunk.', chapter: 'Ch 1', createdAt: 1 },
    ]

    const book = await importEpubFile()
    await flushAsync(10)

    expect(book).not.toBeNull()
    expect(book?.format).toBe('epub')

    // 1. Book row inserted.
    expect(dbRecord.insertCalls).toHaveLength(1)
    expect(dbRecord.insertCalls[0].values).toMatchObject({
      title: 'sample',
      format: 'epub',
    })

    // 2. Cover extracted + book row updated with coverPath.
    expect(extractEpubCover).toHaveBeenCalledTimes(1)
    const coverUpdate = dbRecord.updateCalls.find((u) => 'coverPath' in u.values && u.values.coverPath)
    expect(coverUpdate).toBeDefined()
    expect(coverUpdate?.values.coverPath).toMatch(/\.png$/)

    // 3. R2 upload happened.
    expect(uploadCalls).toHaveLength(1)
    expect(uploadCalls[0].format).toBe('epub')

    // 4. Chunks indexed (chunker called, vectors stored).
    expect(chunkerCalls).toHaveLength(1)
    expect(chunkerCalls[0].format).toBe('epub')
    expect(vectorStoreCalls.insertCalls).toHaveLength(2)
  })
})

describe('file-import — PDF', () => {
  beforeEach(() => resetState())

  it('inserts row, uploads, indexes chunks. No cover extracted.', async () => {
    pickFileResult = { uri: '/Downloads/paper.pdf' }
    chunkerReturn = [
      { id: 'p1', bookId: 'ignored', chunkIndex: 0, text: 'Page 1 text.', chapter: 'Page 1', createdAt: 1 },
    ]

    const book = await importPdfFile()
    await flushAsync(10)

    expect(book?.format).toBe('pdf')
    expect(dbRecord.insertCalls).toHaveLength(1)
    expect(uploadCalls[0].format).toBe('pdf')
    // Cover not extracted for PDF.
    expect(extractEpubCover).not.toHaveBeenCalled()
    expect(vectorStoreCalls.insertCalls).toHaveLength(1)
  })
})

describe('file-import — MOBI / AZW3', () => {
  beforeEach(() => resetState())

  it('uploads as mobi, indexes chunks, no cover', async () => {
    pickFileResult = { uri: '/Downloads/old.mobi' }
    chunkerReturn = [
      { id: 'm1', bookId: 'ignored', chunkIndex: 0, text: 'Mobi chunk.', chapter: 'Ch', createdAt: 1 },
    ]

    const book = await importMobiFile()
    await flushAsync(10)

    expect(book?.format).toBe('mobi')
    expect(uploadCalls[0].format).toBe('mobi')
    expect(extractEpubCover).not.toHaveBeenCalled()
    expect(vectorStoreCalls.insertCalls).toHaveLength(1)
  })

  it('detects .azw3 extension and uploads as mobi', async () => {
    pickFileResult = { uri: '/Downloads/new-book.azw3' }
    chunkerReturn = []

    const book = await importMobiFile()
    await flushAsync(10)

    expect(book?.format).toBe('azw3')
    // azw3 lands in the mobi R2 bucket.
    expect(uploadCalls[0].format).toBe('mobi')
  })
})

describe('file-import — error paths', () => {
  beforeEach(() => resetState())

  it('upload failure leaves the book row in place (post-save side-effect)', async () => {
    pickFileResult = { uri: '/Downloads/sample.epub' }
    uploadShouldFail = true
    chunkerReturn = []

    const book = await importEpubFile()
    await flushAsync(10)

    // Book row WAS inserted because the upload is fire-and-forget after save.
    expect(book).not.toBeNull()
    expect(dbRecord.insertCalls).toHaveLength(1)
    expect(uploadCalls).toHaveLength(1)
  })

  it('indexing failure does NOT delete the book row', async () => {
    pickFileResult = { uri: '/Downloads/sample.epub' }
    chunkerReturn = [
      { id: 'c1', bookId: 'ignored', chunkIndex: 0, text: 'Chunk text.', chapter: null, createdAt: 1 },
    ]
    embedThrows = true
    embeddingReady = true

    const book = await importEpubFile()
    await flushAsync(10)

    // Row still inserted. Indexing will catch the throw inside the embed port
    // (we fall back to server). The point: the import did NOT throw.
    expect(book).not.toBeNull()
    expect(dbRecord.insertCalls).toHaveLength(1)
  })
})

describe('file-import — picker cancellation', () => {
  beforeEach(() => resetState())

  it('returns null when the picker is dismissed', async () => {
    pickFileResult = null
    expect(await importEpubFile()).toBeNull()
    expect(await importPdfFile()).toBeNull()
    expect(await importMobiFile()).toBeNull()
    expect(await importDjvuFile()).toBeNull()
    expect(dbRecord.insertCalls).toEqual([])
  })
})

// H3-03: the shared book-import service's mobile DbPort never called
// triggerSyncOnWrite after inserting the book row or after patching the
// cover. Result: a freshly imported book was marked isDirty=true but the
// next sync didn't fire until either the app was backgrounded or 5
// minutes passed. Users importing a book on launch and immediately
// switching devices saw the book missing on the second device.
//
// The legacy code path (lib/book-storage.insertBook) DID call
// triggerSyncOnWrite, so the divergence was purely between import paths.
describe('file-import — sync trigger after import', () => {
  beforeEach(() => resetState())

  it('triggers a sync push after the book row is inserted', async () => {
    const { triggerSyncOnWrite } = require('@/lib/sync/triggers') as {
      triggerSyncOnWrite: jest.Mock
    }
    pickFileResult = { uri: '/Downloads/syncme.epub' }
    chunkerReturn = []

    await importEpubFile()
    await flushAsync(10)

    expect(dbRecord.insertCalls).toHaveLength(1)
    expect(triggerSyncOnWrite).toHaveBeenCalled()
  })
})
