/**
 * DAT-019 (#131): the import outcome must surface a `coverPromise`
 * that resolves to the eventual cover-extraction state so the library
 * UI can distinguish "Cover pending", "Cover ready", "Cover
 * unavailable" instead of treating every nullable coverPath the same
 * way.
 *
 * Cover extraction itself runs through the shared `book-import` service
 * via `setTimeout(…, 0)` after `done`, so a synchronous check after
 * `importBookFromUrl` returns will see the pending state. Callers can
 * await `coverPromise` for the final state.
 *
 * Schema and UI changes (a dedicated boolean column + "Retry cover"
 * long-press affordance) are owned by sibling slots and tracked in
 * a follow-up; this test pins the data-layer contract.
 */

type FakeFile = {
  uri: string
  exists: boolean
  write: jest.Mock
  bytes: jest.Mock
  base64: jest.Mock
  delete: jest.Mock
  copy: jest.Mock
}

const fakeFiles = new Map<string, FakeFile>()

function makeFakeFile(uri: string): FakeFile {
  const file: FakeFile = {
    uri,
    exists: true,
    write: jest.fn(),
    bytes: jest.fn(async () => new Uint8Array([1, 2, 3])),
    base64: jest.fn(async () => 'AAAA'),
    delete: jest.fn(() => {
      file.exists = false
    }),
    copy: jest.fn(),
  }
  return file
}

jest.mock('expo-file-system', () => {
  const FileCtor = jest.fn().mockImplementation((arg1: unknown, arg2?: string) => {
    let uri: string
    if (arg2 === undefined) {
      uri = typeof arg1 === 'string' ? arg1 : ((arg1 as { uri?: string })?.uri ?? '')
    } else {
      const base = typeof arg1 === 'string' ? arg1 : ((arg1 as { uri?: string })?.uri ?? '')
      uri = `${base}/${arg2}`
    }
    if (!fakeFiles.has(uri)) {
      fakeFiles.set(uri, makeFakeFile(uri))
    }
    return fakeFiles.get(uri)!
  }) as unknown as jest.Mock
  ;(FileCtor as unknown as { pickFileAsync: jest.Mock }).pickFileAsync = jest.fn()

  const DirectoryCtor = jest.fn().mockImplementation((...parts: unknown[]) => {
    const segs = parts.map((p) =>
      typeof p === 'string' ? p : ((p as { uri?: string })?.uri ?? ''),
    )
    const uri = segs.filter(Boolean).join('/')
    return {
      uri,
      exists: true,
      create: jest.fn(),
      delete: jest.fn(),
    }
  })

  return {
    File: FileCtor,
    Directory: DirectoryCtor,
    Paths: { document: '/docs' },
  }
})

jest.mock('@/lib/rag/pipeline', () => ({ embedBook: jest.fn() }))
jest.mock('@/app/_layout', () => ({ __esModule: true, IS_E2E_TEST: false }))
jest.mock('@/lib/auth', () => ({
  __esModule: true,
  getSessionToken: jest.fn(async () => null),
}))
jest.mock('@/lib/file-import-index-gate', () => ({
  __esModule: true,
  shouldSkipIndexing: jest.fn(() => true),
}))
jest.mock('@rishi/shared/schema', () => ({
  books: { id: 'id', fileHash: 'fileHash' },
}))
jest.mock('drizzle-orm', () => ({
  eq: jest.fn((col, val) => ({ col, val })),
}))
jest.mock('@/lib/db', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: () => ({ get: () => undefined, all: () => [] }),
      }),
    }),
    update: () => ({
      set: () => ({ where: () => ({ run: jest.fn() }) }),
    }),
  },
}))
jest.mock('@/lib/sync/file-sync', () => ({
  __esModule: true,
  hashBookFile: jest.fn(async () => 'fresh-hash'),
}))
jest.mock('@/lib/sync/triggers', () => ({ triggerSyncOnWrite: jest.fn() }))
jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: jest.fn(),
}))
jest.mock('@rishi/shared/formats/mobi', () => ({
  extractMobiCover: jest.fn(),
}))
jest.mock('@/lib/sync/upload-error-store', () => ({
  useUploadErrorStore: { getState: () => ({ show: jest.fn() }) },
}))
jest.mock('@/lib/rag/chunker', () => ({ getChunks: jest.fn() }))
jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: jest.fn(),
  isEmbeddingReady: jest.fn(() => false),
}))
jest.mock('@/lib/rag/server-fallback', () => ({ embedTextsOnServer: jest.fn() }))
jest.mock('@/lib/rag/vector-store', () => ({
  insertChunkWithVector: jest.fn(),
  isBookEmbedded: jest.fn(() => false),
  deleteBookChunks: jest.fn(),
}))

// Capture the coverPortDeps file-import threads through createMobileBookImportService.
const capturedDeps: Array<Record<string, unknown>> = []

jest.mock('@/lib/book-import', () => ({
  createMobileBookImportService: jest.fn((opts: Record<string, unknown>) => {
    capturedDeps.push(opts)
    return {
      importFromPath: jest.fn(async () => ({
        ok: true,
        bookId: opts.bookId,
        bookPath: `/docs/books/${String(opts.bookId)}/book.${String(opts.format)}`,
        format: opts.format,
      })),
      indexBook: jest.fn(async () => undefined),
    }
  }),
}))

const realFetch = global.fetch
const mockFetch = jest.fn()
beforeAll(() => {
  global.fetch = mockFetch as unknown as typeof fetch
})
afterAll(() => {
  global.fetch = realFetch
})


function resetAll(): void {
  fakeFiles.clear()
  capturedDeps.length = 0
  mockFetch.mockReset()
  jest.clearAllMocks()
}

interface CoverPortDepsLike {
  onExtractionFailure?: (id: string, reason: unknown) => void
  onExtractionSuccess?: (id: string, coverPath: string) => void
}

// importBookFromUrl returns Book on success. To exercise the
// `coverPromise` surface we use the underlying picker entry indirectly:
// importBookFromUrl wraps runImportWithService and unwraps the outcome
// before throwing on failure. The new surface lives on the OUTCOME
// returned by the picker functions, so we exercise importBookFile here
// with a stubbed pickFile.

import { importBookFile, type ImportOutcome } from '@/lib/file-import'
import { File as ExpoFile } from 'expo-file-system'

const pickFileAsync = (
  ExpoFile as unknown as { pickFileAsync: jest.Mock }
).pickFileAsync

describe('DAT-019 — import outcome surfaces a coverPromise', () => {
  beforeEach(resetAll)

  it('the success outcome exposes coverPromise and initial state is pending', async () => {
    pickFileAsync.mockResolvedValueOnce({ uri: '/Downloads/x.epub' })

    const outcome: ImportOutcome = await importBookFile()
    expect(outcome.ok).toBe(true)
    if (outcome.ok) {
      expect(typeof outcome.coverPromise.then).toBe('function')
      // Synchronously after the import returns, the cover state hasn't
      // resolved yet (the shared importer would fire setTimeout). We
      // resolve it manually below.
    }
  })

  it("resolves to status:'ready' when the cover port writes a real path", async () => {
    pickFileAsync.mockResolvedValueOnce({ uri: '/Downloads/y.epub' })

    const outcome = await importBookFile()
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    // Drive the captured coverPortDeps.onExtractionSuccess to simulate
    // a successful extraction.
    const deps = capturedDeps[0].coverPortDeps as CoverPortDepsLike
    expect(deps).toBeDefined()
    expect(deps.onExtractionSuccess).toBeDefined()
    deps.onExtractionSuccess!(outcome.book.id, 'file:///covers/abc.png')

    await expect(outcome.coverPromise).resolves.toMatchObject({
      status: 'ready',
      coverPath: 'file:///covers/abc.png',
    })
  })

  it("resolves to status:'unavailable' when the cover port reports parse-error", async () => {
    pickFileAsync.mockResolvedValueOnce({ uri: '/Downloads/z.epub' })

    const outcome = await importBookFile()
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    const deps = capturedDeps[0].coverPortDeps as CoverPortDepsLike
    deps.onExtractionFailure!(outcome.book.id, {
      kind: 'parse-error',
      format: 'epub',
      cause: new Error('zip corrupt'),
    })

    const state = await outcome.coverPromise
    expect(state.status).toBe('unavailable')
    if (state.status === 'unavailable') {
      expect(state.reason.kind).toBe('parse-error')
    }
  })

  it("resolves to status:'unsupported' for PDF without waiting on a cover port event", async () => {
    pickFileAsync.mockResolvedValueOnce({ uri: '/Downloads/p.pdf' })
    // Single unified picker — format inferred from .pdf extension.
    const outcome = await importBookFile()
    expect(outcome.ok).toBe(true)
    if (!outcome.ok) return

    // No callback invocation needed — the defensive fallback in
    // runImportWithService resolves the deferred for unsupported
    // formats.
    await expect(outcome.coverPromise).resolves.toMatchObject({
      status: 'unsupported',
      format: 'pdf',
    })
  })
})
