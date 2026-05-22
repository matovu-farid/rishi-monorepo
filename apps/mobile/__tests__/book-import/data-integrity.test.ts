/**
 * Data-integrity regressions for the mobile book-import pipeline.
 *
 *   DAT-001 (#114): Import must not leave an orphan books row when the
 *                   filesystem copy step fails.
 *   DAT-004 (#117): Mid-batch embedding failure must NOT leave the book
 *                   half-indexed — all chunks for that bookId must be
 *                   removed on throw so a retry can run cleanly.
 *   DAT-007 (#120): Concurrent generateChunks(bookId) calls must coalesce
 *                   onto a single in-flight promise; only one insert loop
 *                   runs.
 *
 * The adapters in `apps/mobile/lib/book-import/adapters.ts` wrap mobile-
 * specific I/O for the shared `@rishi/shared/book-import` service. These
 * tests exercise the ports directly so the failure modes are isolated
 * from the picker / service plumbing.
 */

// ── Shared mocks (kept minimal — adapters import lots of native modules) ────
jest.mock('@rishi/shared/schema', () => ({ books: { id: 'id' } }))
jest.mock('drizzle-orm', () => ({ eq: jest.fn((col, val) => ({ col, val })) }))
jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: jest.fn(),
}))
jest.mock('@rishi/shared/formats/mobi', () => ({
  extractMobiCover: jest.fn(),
}))

const dbState = {
  rows: new Map<string, Record<string, unknown>>(),
  insertCalls: [] as Array<Record<string, unknown>>,
  deleteCalls: [] as Array<unknown>,
}

jest.mock('@/lib/db', () => ({
  db: {
    insert: () => ({
      values: (v: Record<string, unknown>) => ({
        run: () => {
          dbState.insertCalls.push(v)
          dbState.rows.set(String(v.id), v)
        },
      }),
    }),
    update: () => ({
      set: () => ({ where: () => ({ run: jest.fn() }) }),
    }),
    delete: () => ({
      where: (w: unknown) => ({
        run: () => {
          dbState.deleteCalls.push(w)
          // Remove rows matching the where filter we receive from drizzle's
          // `eq` mock above (we stored the value in {col,val}).
          if (
            w &&
            typeof w === 'object' &&
            'val' in (w as Record<string, unknown>)
          ) {
            dbState.rows.delete(String((w as { val: unknown }).val))
          }
        },
      }),
    }),
  },
}))

jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: jest.fn(),
}))

jest.mock('@/lib/sync/file-sync', () => ({
  hashBookFile: jest.fn(),
  uploadBookFile: jest.fn(),
  UploadLimitError: class extends Error {},
}))

jest.mock('@/lib/sync/upload-error-store', () => ({
  useUploadErrorStore: { getState: () => ({ show: jest.fn() }) },
}))

// expo-file-system: track which directories were created + simulate copy
// throwing on demand.
let copyShouldThrow = false
const createdDirs: string[] = []

jest.mock('expo-file-system', () => {
  const Paths = { document: '/docs' }

  class Directory {
    uri: string
    exists = true
    constructor(arg1: unknown, name?: string) {
      const base =
        typeof arg1 === 'string'
          ? arg1
          : ((arg1 as { uri?: string })?.uri ?? '/docs')
      this.uri = name ? `${base}/${name}` : base
    }
    create(_opts?: unknown) {
      createdDirs.push(this.uri)
    }
  }

  class File {
    uri: string
    constructor(arg1: unknown, name?: string) {
      const base =
        typeof arg1 === 'string'
          ? arg1
          : ((arg1 as { uri?: string })?.uri ?? '/docs')
      this.uri = name ? `${base}/${name}` : base
    }
    copy(_dest: unknown) {
      if (copyShouldThrow) throw new Error('ENOSPC: out of disk')
    }
    delete() {
      /* no-op */
    }
    write() {
      /* no-op */
    }
    async bytes(): Promise<Uint8Array> {
      return new Uint8Array()
    }
    get size(): number {
      return 0
    }
  }

  return { File, Directory, Paths }
})

// rag/chunker + embedder + vector-store: tests configure these per-suite.
const chunkerState = {
  chunks: [] as Array<{
    id: string
    chunkIndex: number
    text: string
    chapter: string | null
  }>,
  callCount: 0,
}
jest.mock('@/lib/rag/chunker', () => ({
  getChunks: jest.fn(async () => {
    chunkerState.callCount += 1
    return chunkerState.chunks
  }),
}))

const embedderState = {
  ready: true,
  throwOnCall: 0, // 0 = never; N = throw on the Nth call (1-indexed)
  callCount: 0,
}
jest.mock('@/lib/rag/embedder', () => ({
  isEmbeddingReady: jest.fn(() => embedderState.ready),
  embedBatch: jest.fn(async (texts: string[]) => {
    embedderState.callCount += 1
    if (
      embedderState.throwOnCall > 0 &&
      embedderState.callCount === embedderState.throwOnCall
    ) {
      throw new Error('embed failed mid-batch')
    }
    return texts.map(() => new Array(384).fill(0.1))
  }),
}))

const serverState = {
  throwOnCall: 0,
  callCount: 0,
}
jest.mock('@/lib/rag/server-fallback', () => ({
  embedTextsOnServer: jest.fn(async (texts: string[]) => {
    serverState.callCount += 1
    if (
      serverState.throwOnCall > 0 &&
      serverState.callCount === serverState.throwOnCall
    ) {
      throw new Error('server embed failed mid-batch')
    }
    return texts.map(() => new Array(384).fill(0.5))
  }),
}))

const vectorState = {
  insertCalls: [] as Array<{
    chunkId: string
    bookId: string
    chunkIndex: number
  }>,
  deletedBookIds: [] as string[],
  /** Set bookId here to make `isBookEmbedded` return true. */
  embeddedBookIds: new Set<string>(),
}
jest.mock('@/lib/rag/vector-store', () => ({
  insertChunkWithVector: jest.fn(
    (
      chunkId: string,
      bookId: string,
      chunkIndex: number,
      _text: string,
      _chapter: string | null,
      _embedding: number[],
    ) => {
      vectorState.insertCalls.push({ chunkId, bookId, chunkIndex })
    },
  ),
  isBookEmbedded: jest.fn((bookId: string) =>
    vectorState.embeddedBookIds.has(bookId),
  ),
  deleteBookChunks: jest.fn((bookId: string) => {
    vectorState.deletedBookIds.push(bookId)
    vectorState.insertCalls = vectorState.insertCalls.filter(
      (c) => c.bookId !== bookId,
    )
  }),
}))

import {
  createMobileDbPort,
  createMobileFsPort,
  createMobileEmbedPort,
} from '@/lib/book-import/adapters'

function resetAll() {
  dbState.rows.clear()
  dbState.insertCalls.length = 0
  dbState.deleteCalls.length = 0
  createdDirs.length = 0
  copyShouldThrow = false
  chunkerState.chunks = []
  chunkerState.callCount = 0
  embedderState.ready = true
  embedderState.throwOnCall = 0
  embedderState.callCount = 0
  serverState.throwOnCall = 0
  serverState.callCount = 0
  vectorState.insertCalls.length = 0
  vectorState.deletedBookIds.length = 0
  vectorState.embeddedBookIds.clear()
  jest.clearAllMocks()
}

// ────────────────────────────────────────────────────────────────────────────
// DAT-001 — atomic insert: copy failure leaves NO orphan books row.
// ────────────────────────────────────────────────────────────────────────────

describe('DAT-001 — atomic insert vs file copy', () => {
  beforeEach(resetAll)

  /**
   * Drive the shape the shared service would: call FsPort.copyBookToAppData
   * FIRST, and only on success call DbPort.saveBook. We assert that when
   * the copy step throws the DbPort is never asked to insert and no row
   * exists. This pins the contract that the shared service enforces.
   */
  it('does not insert a books row when copyBookToAppData throws', async () => {
    copyShouldThrow = true
    const fs = createMobileFsPort({ bookId: 'b-fail', format: 'epub' })
    const db = createMobileDbPort()

    let copied = false
    let inserted = false
    try {
      await fs.copyBookToAppData('/Downloads/x.epub')
      copied = true
      await db.saveBook({
        id: 'b-fail',
        title: 't',
        author: 'a',
        coverPath: null,
        filePath: '/docs/books/b-fail/book.epub',
        format: 'epub',
        currentCfi: null,
        currentPage: null,
        createdAt: 1,
      })
      inserted = true
    } catch {
      /* expected */
    }

    expect(copied).toBe(false)
    expect(inserted).toBe(false)
    expect(dbState.insertCalls).toHaveLength(0)
    expect(dbState.rows.size).toBe(0)
  })

  /**
   * The other failure mode the issue surfaces: saveBook itself can fail
   * mid-way (the row write succeeds but a follow-up step inside the
   * adapter throws). The adapter must roll back the inserted row before
   * propagating the error so callers can retry without an orphan.
   */
  it('rolls back the inserted row when saveBook fails after the row write', async () => {
    const triggers = require('@/lib/sync/triggers') as {
      triggerSyncOnWrite: jest.Mock
    }
    triggers.triggerSyncOnWrite.mockImplementationOnce(() => {
      throw new Error('sync trigger blew up')
    })

    const db = createMobileDbPort()

    await expect(
      db.saveBook({
        id: 'b-rollback',
        title: 't',
        author: 'a',
        coverPath: null,
        filePath: '/docs/books/b-rollback/book.epub',
        format: 'epub',
        currentCfi: null,
        currentPage: null,
        createdAt: 1,
      }),
    ).rejects.toThrow()

    // Row was inserted then deleted as part of rollback — net effect: gone.
    expect(dbState.insertCalls).toHaveLength(1)
    expect(dbState.deleteCalls).toHaveLength(1)
    expect(dbState.rows.has('b-rollback')).toBe(false)
  })
})

// ────────────────────────────────────────────────────────────────────────────
// DAT-004 — embedding failure mid-batch must leave NO chunks for that book.
// ────────────────────────────────────────────────────────────────────────────

describe('DAT-004 — embedding failure rolls back chunks', () => {
  beforeEach(resetAll)

  it('removes all inserted chunks when a later batch throws', async () => {
    // 15 chunks → 2 batches of 10 + 5. Force the server path (on-device
    // not ready) and make the SECOND server embed call throw. This pins
    // the recoverable-failure mode: the FIRST batch's 10 chunks already
    // landed in sqlite, then the second batch blew up; without rollback
    // isBookEmbedded would (wrongly) return true forever after.
    chunkerState.chunks = Array.from({ length: 15 }, (_, i) => ({
      id: `c-${i}`,
      chunkIndex: i,
      text: `t-${i}`,
      chapter: null,
    }))
    embedderState.ready = false // force server fallback
    serverState.throwOnCall = 2

    const port = createMobileEmbedPort()

    await expect(
      port.generateChunks({
        bookId: 'book-half' as unknown as string,
        filePath: '/docs/books/book-half/book.epub',
        format: 'epub',
      }),
    ).rejects.toThrow(/embed failed/i)

    // Critical: NO chunks remain for the failed book. The next retry can
    // re-run cleanly.
    expect(
      vectorState.insertCalls.filter((c) => c.bookId === 'book-half'),
    ).toHaveLength(0)
    expect(vectorState.deletedBookIds).toContain('book-half')
  })

  it('does not delete chunks for OTHER books on failure', async () => {
    // Pre-populate as if another book is fully embedded.
    vectorState.insertCalls.push({
      chunkId: 'other-1',
      bookId: 'other-book',
      chunkIndex: 0,
    })

    chunkerState.chunks = Array.from({ length: 11 }, (_, i) => ({
      id: `c-${i}`,
      chunkIndex: i,
      text: `t-${i}`,
      chapter: null,
    }))
    embedderState.ready = false
    serverState.throwOnCall = 2

    const port = createMobileEmbedPort()
    await expect(
      port.generateChunks({
        bookId: 'book-fail' as unknown as string,
        filePath: '/p',
        format: 'epub',
      }),
    ).rejects.toThrow()

    expect(
      vectorState.insertCalls.filter((c) => c.bookId === 'other-book'),
    ).toHaveLength(1)
    expect(vectorState.deletedBookIds).toEqual(['book-fail'])
  })
})

// ────────────────────────────────────────────────────────────────────────────
// DAT-007 — in-flight lock: concurrent generateChunks coalesce.
// ────────────────────────────────────────────────────────────────────────────

describe('DAT-007 — generateChunks in-flight lock', () => {
  beforeEach(resetAll)

  it('runs only ONE insert loop for two concurrent calls on the same bookId', async () => {
    chunkerState.chunks = [
      { id: 'c-0', chunkIndex: 0, text: 't-0', chapter: null },
      { id: 'c-1', chunkIndex: 1, text: 't-1', chapter: null },
      { id: 'c-2', chunkIndex: 2, text: 't-2', chapter: null },
    ]

    const port = createMobileEmbedPort()

    const [a, b] = await Promise.all([
      port.generateChunks({
        bookId: 'book-race' as unknown as string,
        filePath: '/p',
        format: 'epub',
      }),
      port.generateChunks({
        bookId: 'book-race' as unknown as string,
        filePath: '/p',
        format: 'epub',
      }),
    ])

    // Chunker called once — second caller awaited the same in-flight promise.
    expect(chunkerState.callCount).toBe(1)
    // Exactly one set of vectors written (3 chunks, no duplicates).
    expect(
      vectorState.insertCalls.filter((c) => c.bookId === 'book-race'),
    ).toHaveLength(3)
    // Both callers see a result (return shape doesn't matter — the contract
    // is "they coalesce" not "they return the same array reference").
    expect(Array.isArray(a)).toBe(true)
    expect(Array.isArray(b)).toBe(true)
  })

  it('releases the lock after completion so a fresh call can run again', async () => {
    chunkerState.chunks = [
      { id: 'c-0', chunkIndex: 0, text: 't-0', chapter: null },
    ]
    const port = createMobileEmbedPort()

    await port.generateChunks({
      bookId: 'book-release' as unknown as string,
      filePath: '/p',
      format: 'epub',
    })
    // Pretend a retry/reindex happens. The lock must have cleared so the
    // chunker is asked again.
    chunkerState.callCount = 0
    vectorState.embeddedBookIds.delete('book-release')

    await port.generateChunks({
      bookId: 'book-release' as unknown as string,
      filePath: '/p',
      format: 'epub',
    })

    expect(chunkerState.callCount).toBe(1)
  })

  it('releases the lock on failure so a retry can run', async () => {
    chunkerState.chunks = [
      { id: 'c-0', chunkIndex: 0, text: 't-0', chapter: null },
    ]
    embedderState.ready = false
    serverState.throwOnCall = 1

    const port = createMobileEmbedPort()

    await expect(
      port.generateChunks({
        bookId: 'book-retry' as unknown as string,
        filePath: '/p',
        format: 'epub',
      }),
    ).rejects.toThrow()

    // Reset embedder to succeed; retry must actually re-run the pipeline.
    serverState.throwOnCall = 0
    serverState.callCount = 0
    chunkerState.callCount = 0

    await port.generateChunks({
      bookId: 'book-retry' as unknown as string,
      filePath: '/p',
      format: 'epub',
    })

    expect(chunkerState.callCount).toBe(1)
  })
})
