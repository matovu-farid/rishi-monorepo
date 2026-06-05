/**
 * Task 9 — Wire extraction runner into file-import.ts
 *
 * Verifies that after a successful PDF import, enqueueExtraction is called
 * fire-and-forget, and that EPUB imports do NOT trigger extraction.
 *
 * Strategy: mock @/lib/pdf/extraction-runner so we can spy on
 * enqueueExtraction without needing a real SQLite engine here. All other
 * mocks are copied verbatim from __tests__/book-import/file-import.test.ts
 * so the import path works end-to-end.
 */

// ─── Mock app/_layout (pulls in @react-navigation/native which is ESM-only) ──
jest.mock('@/app/_layout', () => ({ IS_E2E_TEST: false }))

// ─── Mock auth + index-gate ───────────────────────────────────────────────────
jest.mock('@/lib/auth', () => ({
  getSessionToken: jest.fn(async () => 'fake-token'),
}))
jest.mock('@/lib/file-import-index-gate', () => ({
  shouldSkipIndexing: jest.fn(() => true), // skip indexing — not under test here
}))

// ─── Mock the extraction runner (under test) ────────────────────────────────
const enqueueExtractionMock = jest.fn(async () => {})
jest.mock('@/lib/pdf/extraction-runner', () => ({
  enqueueExtraction: enqueueExtractionMock,
  waitForIdle: jest.fn(async () => {}),
  __resetRunnerForTests: jest.fn(),
}))

// ─── Native module fakes (same pattern as file-import.test.ts) ──────────────

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
    copy: jest.fn((dest: FakeFile) => { dest.exists = true }),
    write: jest.fn(),
    bytes: jest.fn(async () => opts?.bytes ?? new Uint8Array([1, 2, 3])),
    base64: jest.fn(async () => 'dGVzdA=='),
    delete: jest.fn(() => { file.exists = false }),
  }
  return file
}

jest.mock('expo-file-system', () => {
  const FileCtor = jest.fn().mockImplementation((arg1: any, arg2?: string) => {
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
    return { uri, exists: true, create: jest.fn() }
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

jest.mock('@/lib/db', () => ({
  db: {
    insert: (_table: any) => ({
      values: (values: any) => ({ run: () => {} }),
    }),
    update: (_table: any) => ({
      set: (v: any) => ({
        where: (w: any) => ({ run: () => {} }),
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
  },
  rawDb: {
    execSync: jest.fn(),
    runSync: jest.fn(),
    getAllSync: jest.fn(() => []),
    loadExtensionSync: jest.fn(),
  },
}))

jest.mock('@/lib/sync/triggers', () => ({
  triggerSyncOnWrite: jest.fn(),
}))

const uploadCalls: any[] = []
jest.mock('@/lib/sync/file-sync', () => ({
  hashBookFile: jest.fn(async () => 'fake-hash'),
  uploadBookFile: jest.fn(async (path: string, hash: string, format: string) => {
    uploadCalls.push({ path, hash, format })
    return { r2Key: `r2/${format}/${hash}` }
  }),
}))

jest.mock('@/lib/rag/chunker', () => ({
  getChunks: jest.fn(async () => []),
}))

jest.mock('@/lib/rag/embedder', () => ({
  embedBatch: jest.fn(async (texts: string[]) => texts.map(() => [0.1, 0.2, 0.3])),
  isEmbeddingReady: jest.fn(() => true),
}))

jest.mock('@/lib/rag/server-fallback', () => ({
  embedTextsOnServer: jest.fn(async (texts: string[]) => texts.map(() => [0.5, 0.5, 0.5])),
}))

jest.mock('@/lib/rag/vector-store', () => ({
  insertChunkWithVector: jest.fn(),
  isBookEmbedded: jest.fn(() => false),
  deleteBookChunks: jest.fn(),
}))

jest.mock('@/lib/book-storage', () => ({
  insertBook: jest.fn(),
}))

jest.mock('@rishi/shared/formats/epub-cover', () => ({
  extractEpubCover: jest.fn(async () => null),
}))

// ─── Imports (after all mocks) ───────────────────────────────────────────────

import { importBookFile } from '@/lib/file-import'

async function flushAsync(ticks = 10) {
  for (let i = 0; i < ticks; i++) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

function resetState() {
  fakeFiles.clear()
  uploadCalls.length = 0
  pickFileResult = null
  enqueueExtractionMock.mockClear()
  jest.clearAllMocks()
  // Re-apply enqueue mock so clearAllMocks doesn't wipe it
  enqueueExtractionMock.mockImplementation(async () => {})
}

// ─── Tests ───────────────────────────────────────────────────────────────────

describe('file-import — extraction wiring', () => {
  beforeEach(() => resetState())

  it('calls enqueueExtraction after a successful PDF import', async () => {
    pickFileResult = { uri: '/Downloads/paper.pdf' }

    const result = await importBookFile()
    await flushAsync()

    expect(result).toMatchObject({ ok: true })
    expect(enqueueExtractionMock).toHaveBeenCalledTimes(1)
    expect(enqueueExtractionMock).toHaveBeenCalledWith(
      expect.objectContaining({
        bookId: expect.any(String),
        filePath: expect.stringContaining('.pdf'),
      }),
    )
  })

  it('does NOT call enqueueExtraction after an EPUB import', async () => {
    pickFileResult = { uri: '/Downloads/sample.epub' }

    const result = await importBookFile()
    await flushAsync()

    expect(result).toMatchObject({ ok: true })
    expect(enqueueExtractionMock).not.toHaveBeenCalled()
  })
})
