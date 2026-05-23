import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mkdtempSync, writeFileSync, existsSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

// ---------------------------------------------------------------------------
// Mock electron — vectordb/index.ts imports `app` at module top-level.
// ---------------------------------------------------------------------------

let userDataDir = ''

vi.mock('electron', () => ({
  app: {
    getPath: () => userDataDir,
    on: () => {}
  }
}))

// ---------------------------------------------------------------------------
// Mock hnswlib-node so tests don't depend on the native binary and we can
// drive corruption/dim-mismatch deterministically.
// ---------------------------------------------------------------------------

class FakeHNSW {
  static failNextRead: Error | null = null
  // If set, readIndexSync will pretend the stored index has this dim.
  static nextLoadedDim: number | null = null
  // Last constructed instance — handy for assertions in tests.
  static lastInstance: FakeHNSW | null = null

  space: string
  dim: number
  loadedDim: number
  count = 0
  maxElements = 0
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  points = new Map<number, number[]>()

  constructor(space: string, dim: number) {
    this.space = space
    this.dim = dim
    this.loadedDim = dim
    FakeHNSW.lastInstance = this
  }

  initIndex(maxElements: number, _m?: number, _ef?: number, _seed?: number, _replace?: boolean): void {
    this.maxElements = maxElements
  }

  readIndexSync(filename: string, _allowReplace?: boolean): void {
    if (FakeHNSW.failNextRead) {
      const e = FakeHNSW.failNextRead
      FakeHNSW.failNextRead = null
      throw e
    }
    // A valid pre-existing index pretends to have `nextLoadedDim` (or
    // ctor dim by default) and one stored point so getCurrentCount > 0.
    if (FakeHNSW.nextLoadedDim != null) {
      this.loadedDim = FakeHNSW.nextLoadedDim
      FakeHNSW.nextLoadedDim = null
    }
    // Confirm the file exists so tests that check unlink behaviour work
    if (!existsSync(filename)) {
      throw new Error(`Fake hnsw: file not found ${filename}`)
    }
    this.maxElements = 1000
    this.count = 1
    this.points.set(0, new Array(this.loadedDim).fill(0.1))
  }

  writeIndexSync(_filename: string): void {
    // No-op — we don't actually need bytes on disk for tests.
  }

  setEf(_ef: number): void {}

  resizeIndex(n: number): void {
    this.maxElements = n
  }

  addPoint(point: number[], label: number, _replace?: boolean): void {
    this.points.set(label, point)
    this.count = this.points.size
  }

  getCurrentCount(): number {
    return this.count
  }

  getMaxElements(): number {
    return this.maxElements
  }

  getNumDimensions(): number {
    return this.loadedDim
  }

  searchKnn(_q: number[], k: number) {
    const ids = Array.from(this.points.keys()).slice(0, k)
    return {
      neighbors: ids,
      distances: ids.map((_, i) => i * 0.1)
    }
  }
}

// Import after mocks so they take effect.
import {
  initVectorDb,
  saveVectors,
  searchVectors,
  hasVectorsForBook,
  rebuildIndexFromChunks,
  isIndexRebuilding,
  _resetForTesting,
  _setHnswForTesting
} from './index.js'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeVec(dim: number, fill: number): number[] {
  return new Array(dim).fill(fill)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('vectordb index recovery', () => {
  let tmpRoot: string

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), 'vectordb-test-'))
    userDataDir = tmpRoot
    FakeHNSW.failNextRead = null
    FakeHNSW.nextLoadedDim = null
    FakeHNSW.lastInstance = null
    _resetForTesting()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    _setHnswForTesting(FakeHNSW as any)
    initVectorDb()
  })

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true })
  })

  // -------------------------------------------------------------------------
  // Happy path
  // -------------------------------------------------------------------------

  it('loads a valid existing index without rebuild', () => {
    // Seed an "existing" index file. FakeHNSW.readIndexSync will succeed.
    const indexFile = join(tmpRoot, 'vectordb', '7-vectordb.hnsw')
    writeFileSync(indexFile, 'pretend-this-is-a-real-index')

    expect(hasVectorsForBook(7)).toBe(true)

    // Saving more vectors at the same dim should load the existing file
    // (not start fresh) and not unlink it.
    saveVectors('7-vectordb', 384, [{ id: 99, vector: makeVec(384, 0.2) }])

    expect(existsSync(indexFile)).toBe(true)
    expect(isIndexRebuilding('7-vectordb')).toBe(false)
  })

  // -------------------------------------------------------------------------
  // Corruption recovery
  // -------------------------------------------------------------------------

  it('recovers from a corrupt index file by unlinking and starting fresh', () => {
    // Place a junk file at the index path.
    const indexFile = join(tmpRoot, 'vectordb', '12-vectordb.hnsw')
    writeFileSync(indexFile, 'not-a-real-hnsw-payload')

    // Next readIndexSync will throw — simulating a corrupt/truncated file.
    FakeHNSW.failNextRead = new Error('hnswlib: failed to parse index header')

    // Should NOT throw. Recovery path should unlink the bad file and
    // proceed with a fresh in-memory index.
    expect(() =>
      saveVectors('12-vectordb', 384, [{ id: 1, vector: makeVec(384, 0.3) }])
    ).not.toThrow()

    // The corrupt file must have been removed (then re-saved as a fresh
    // index by writeIndexSync — but FakeHNSW.writeIndexSync is a no-op,
    // so the file should be absent now).
    expect(existsSync(indexFile)).toBe(false)
  })

  it('searchVectors does not throw when the on-disk index is corrupt', () => {
    const indexFile = join(tmpRoot, 'vectordb', '20-vectordb.hnsw')
    writeFileSync(indexFile, 'corrupt')
    FakeHNSW.failNextRead = new Error('truncated file')

    // Search must not crash the renderer-facing IPC path; return empty.
    const results = searchVectors('20-vectordb', makeVec(384, 0.1), 384, 5)
    expect(results).toEqual([])
    expect(existsSync(indexFile)).toBe(false)
  })

  // -------------------------------------------------------------------------
  // Dimension mismatch
  // -------------------------------------------------------------------------

  it('detects a dim mismatch and rebuilds the index with the new dim', () => {
    // Existing on-disk index claims dim 768 (a previous, larger model)
    const indexFile = join(tmpRoot, 'vectordb', '30-vectordb.hnsw')
    writeFileSync(indexFile, 'pretend-old-index')
    FakeHNSW.nextLoadedDim = 768

    // Now the caller arrives with dim 384 (current model). Saving must
    // succeed without throwing, must unlink the old file, and must
    // construct a new index sized for 384.
    expect(() =>
      saveVectors('30-vectordb', 384, [{ id: 5, vector: makeVec(384, 0.5) }])
    ).not.toThrow()

    // The stale file must have been unlinked. The fresh index isn't
    // persisted by the fake, so the file should NOT exist.
    expect(existsSync(indexFile)).toBe(false)

    // The most recently constructed FakeHNSW must have the new dim.
    expect(FakeHNSW.lastInstance?.dim).toBe(384)
  })

  // -------------------------------------------------------------------------
  // rebuildIndexFromChunks
  // -------------------------------------------------------------------------

  it('rebuildIndexFromChunks re-embeds chunks and populates a fresh index', async () => {
    // No pre-existing file. Provide a chunk loader + embedder.
    const chunks = [
      { id: 1, text: 'first chunk' },
      { id: 2, text: 'second chunk' }
    ]
    const embedder = vi.fn(async (texts: Array<{ id: number; text: string }>) =>
      texts.map((t) => ({ id: t.id, vector: makeVec(384, 0.7) }))
    )

    await rebuildIndexFromChunks('40-vectordb', 384, async () => chunks, embedder)

    expect(embedder).toHaveBeenCalledOnce()
    // After rebuild the in-memory index should have both points.
    const results = searchVectors('40-vectordb', makeVec(384, 0.7), 384, 2)
    expect(results.length).toBe(2)
    expect(new Set(results.map((r) => r.id))).toEqual(new Set([1, 2]))
  })

  it('rebuildIndexFromChunks marks index as rebuilding while running', async () => {
    let resolveLoader: ((v: Array<{ id: number; text: string }>) => void) | undefined
    const loader = () =>
      new Promise<Array<{ id: number; text: string }>>((resolve) => {
        resolveLoader = resolve
      })
    const embedder = vi.fn(async (texts: Array<{ id: number; text: string }>) =>
      texts.map((t) => ({ id: t.id, vector: makeVec(384, 0.4) }))
    )

    const promise = rebuildIndexFromChunks('50-vectordb', 384, loader, embedder)

    // While the loader is pending, the index should be flagged as rebuilding.
    expect(isIndexRebuilding('50-vectordb')).toBe(true)

    resolveLoader?.([{ id: 1, text: 'x' }])
    await promise

    expect(isIndexRebuilding('50-vectordb')).toBe(false)
  })
})
