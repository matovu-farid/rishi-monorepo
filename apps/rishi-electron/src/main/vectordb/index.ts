import { app } from 'electron'
import { join } from 'path'
import { mkdirSync, existsSync, unlinkSync } from 'fs'
import type * as HnswLib from 'hnswlib-node'
import { errorMessage } from '../utils/errors.js'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface IndexEntry {
  index: InstanceType<HierarchicalNSWType>
  dim: number
  count: number
  maxElements: number
}

// hnswlib-node is a native module — resolve its constructor type lazily so
// the rest of the app can still boot when the binary is unavailable.
type HierarchicalNSWType = typeof HnswLib.HierarchicalNSW

let HierarchicalNSW: HierarchicalNSWType | null = null

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

/** Directory where `.hnsw` index files are persisted. */
let storageDir = ''

/** In-memory cache of loaded HNSW indices, keyed by name. */
const indices = new Map<string, IndexEntry>()

/**
 * Names of indices currently being rebuilt in the background. Search calls
 * can consult `isIndexRebuilding(name)` to surface a "ready in a moment"
 * UX instead of returning empty results that look like a missing book.
 */
const rebuilding = new Set<string>()

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const DEFAULT_DIM = 384
const DEFAULT_MAX_ELEMENTS = 10_000
const EF_CONSTRUCTION = 200
const M = 16
const DEFAULT_EF_SEARCH = 50

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function indexPath(name: string): string {
  return join(storageDir, `${name}.hnsw`)
}

/**
 * Attempt to import hnswlib-node at runtime. Throws a descriptive error when
 * the native module cannot be loaded (e.g. missing binary for the current
 * platform).
 */
function requireHnsw(): HierarchicalNSWType {
  if (HierarchicalNSW) return HierarchicalNSW

  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('hnswlib-node') as typeof HnswLib
    HierarchicalNSW = mod.HierarchicalNSW
    return HierarchicalNSW
  } catch (err) {
    throw new Error(
      `hnswlib-node is not available on this platform. ` +
        `Vector search will be unavailable. ` +
        `Original error: ${errorMessage(err)}`
    )
  }
}

/**
 * Create a brand-new HNSW index with the given dimensions and capacity.
 */
function createIndex(dim: number, maxElements: number): InstanceType<HierarchicalNSWType> {
  const HNSW = requireHnsw()
  const index = new HNSW('cosine', dim)
  // 5th arg `allowReplaceDeleted` must be true so saveVectors can call
  // addPoint(..., replaceDeleted=true) when re-embedding existing chunks.
  index.initIndex(maxElements, M, EF_CONSTRUCTION, 100, true)
  index.setEf(DEFAULT_EF_SEARCH)
  return index
}

/**
 * Best-effort unlink of a corrupted / mismatched index artifact. Swallows
 * ENOENT and logs any other error so caller code can continue with a fresh
 * in-memory index even when the disk is in a weird state (FIO-005).
 */
function unlinkBrokenIndex(name: string, reason: string): void {
  const filePath = indexPath(name)
  try {
    if (existsSync(filePath)) {
      unlinkSync(filePath)
      console.warn(
        `[vectordb] removed broken index file for "${name}" (${reason}); ` +
          `it will be rebuilt from chunk_data on next indexer pass.`
      )
    }
  } catch (err) {
    console.error(
      `[vectordb] failed to unlink broken index "${name}" (${reason}): ${errorMessage(err)}`
    )
  }
}

/**
 * Load an existing index from disk, or return `undefined` if the file does
 * not exist, is corrupted, or has a dimension that doesn't match the
 * embedder the caller is using.
 *
 * On corruption / dim mismatch the broken file is unlinked so the next
 * write produces a clean artifact. Callers may then trigger a background
 * `rebuildIndexFromChunks` to repopulate from the SQLite chunk corpus.
 */
function loadIndexFromDisk(name: string, dim: number): IndexEntry | undefined {
  const filePath = indexPath(name)
  if (!existsSync(filePath)) return undefined

  const HNSW = requireHnsw()
  const index = new HNSW('cosine', dim)

  try {
    // 2nd arg `allowReplaceDeleted` must match what createIndex sets so
    // addPoint(..., replaceDeleted=true) works for indices loaded from disk.
    index.readIndexSync(filePath, true)
  } catch (err) {
    // Truncated, partial write (disk full at last save), bit-rotted file,
    // schema bump in hnswlib, etc. Treat as unrecoverable: drop the file
    // and signal "no existing index" so the caller starts fresh.
    unlinkBrokenIndex(name, `load failed: ${errorMessage(err)}`)
    return undefined
  }

  // Dimension mismatch: the embedder model was swapped (e.g. MiniLM-L6
  // 384-dim -> MiniLM-L12 768-dim) since this file was written. The old
  // vectors are meaningless against the new model; rebuild from source
  // chunks instead of crashing on the first addPoint/searchKnn call.
  let storedDim = dim
  try {
    storedDim = index.getNumDimensions()
  } catch {
    // Older hnswlib builds may not expose getNumDimensions; trust the
    // ctor dim and let downstream addPoint surface a clean error.
  }
  if (storedDim !== dim) {
    unlinkBrokenIndex(
      name,
      `dim mismatch: stored=${storedDim} live=${dim} (embedder model changed)`
    )
    return undefined
  }

  index.setEf(DEFAULT_EF_SEARCH)

  const count = index.getCurrentCount()
  const maxElements = index.getMaxElements()

  return { index, dim, count, maxElements }
}

/**
 * Retrieve an IndexEntry from the in-memory cache, loading from disk when
 * necessary. Returns `undefined` when no persisted index exists (or the
 * persisted index was corrupted / dim-mismatched and got unlinked).
 */
function getOrLoadIndex(name: string, dim: number): IndexEntry | undefined {
  const cached = indices.get(name)
  if (cached) return cached

  const loaded = loadIndexFromDisk(name, dim)
  if (loaded) {
    indices.set(name, loaded)
  }
  return loaded
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Initialise the vector database storage directory. This must be called once
 * at startup (after `app.whenReady()`).
 */
export function initVectorDb(): void {
  storageDir = join(app.getPath('userData'), 'vectordb')
  mkdirSync(storageDir, { recursive: true })
}

/**
 * Returns true if a persisted HNSW index file exists for the given book, or
 * if the index is already loaded in the in-memory cache.
 */
export function hasVectorsForBook(bookId: number): boolean {
  const name = `${bookId}-vectordb`
  if (indices.has(name)) return true
  return existsSync(indexPath(name))
}

/**
 * Returns true when a background rebuild is in progress for `name`. The
 * renderer can surface a "search is warming up" hint instead of treating
 * the empty-result window as "this book has no content".
 */
export function isIndexRebuilding(name: string): boolean {
  return rebuilding.has(name)
}

/**
 * Insert (or update) vectors into the index identified by `name`.
 *
 * If the index does not yet exist it is created with the provided dimension.
 * The index is automatically resized when the number of stored vectors
 * exceeds its current capacity.
 *
 * @param name   - A unique key identifying the index (typically a book id).
 * @param dim    - Dimensionality of the vectors (default 384).
 * @param vectors - The vectors to upsert, each with a numeric id.
 */
export function saveVectors(
  name: string,
  dim: number = DEFAULT_DIM,
  vectors: Array<{ id: number; vector: number[] }>
): void {
  if (vectors.length === 0) return

  let entry = getOrLoadIndex(name, dim)

  if (!entry) {
    const maxElements = Math.max(DEFAULT_MAX_ELEMENTS, vectors.length)
    const index = createIndex(dim, maxElements)
    entry = { index, dim, count: 0, maxElements }
    indices.set(name, entry)
  }

  // Resize if necessary
  const requiredCapacity = entry.count + vectors.length
  if (requiredCapacity > entry.maxElements) {
    const newMax = Math.max(requiredCapacity, entry.maxElements * 2)
    entry.index.resizeIndex(newMax)
    entry.maxElements = newMax
  }

  // Add vectors
  for (const { id, vector } of vectors) {
    if (vector.length !== dim) {
      throw new Error(
        `Vector dimension mismatch for id ${id}: expected ${dim}, got ${vector.length}`
      )
    }
    entry.index.addPoint(vector, id, true /* replace_deleted */)
  }

  entry.count = entry.index.getCurrentCount()

  // Persist to disk
  entry.index.writeIndexSync(indexPath(name))
}

/**
 * Search the index identified by `name` for the `k` nearest neighbours of
 * `query`.
 *
 * @returns An array of results sorted by ascending distance (best match
 *          first). Returns an empty array when the index does not exist,
 *          could not be loaded (corruption / dim mismatch — recovery path
 *          kicks in), or contains no vectors.
 */
export function searchVectors(
  name: string,
  query: number[],
  dim: number = DEFAULT_DIM,
  k: number = 5
): Array<{ id: number; distance: number }> {
  // getOrLoadIndex performs corruption/dim-mismatch recovery: a returned
  // `undefined` here means "no usable index right now" rather than an
  // unhandled crash. The renderer treats that as an empty result set,
  // and the next indexBook pass will repopulate vectors lazily.
  const entry = getOrLoadIndex(name, dim)
  if (!entry || entry.count === 0) return []

  if (query.length !== dim) {
    throw new Error(`Query dimension mismatch: expected ${dim}, got ${query.length}`)
  }

  // Clamp k to the number of available vectors
  const effectiveK = Math.min(k, entry.count)
  if (effectiveK === 0) return []

  const result = entry.index.searchKnn(query, effectiveK)

  // Combine neighbours and distances into a sorted array
  const results: Array<{ id: number; distance: number }> = []
  for (let i = 0; i < result.neighbors.length; i++) {
    results.push({
      id: result.neighbors[i],
      distance: result.distances[i]
    })
  }

  // Sort ascending by distance (closest first)
  results.sort((a, b) => a.distance - b.distance)

  return results
}

/**
 * Rebuild an index `name` from its source chunks. Used after corruption or
 * a dim-mismatch wipe to repopulate from SQLite `chunk_data`.
 *
 * The caller supplies:
 *   - `loadChunks`: an async function that returns the chunk corpus
 *     (typically `getAllPageDataByBookId(bookId)` from the queries module).
 *   - `embed`: an async function that maps chunks -> `{id, vector}` pairs
 *     (typically `generateEmbeddings(...).map(...)`).
 *
 * While the rebuild runs the index is flagged via `isIndexRebuilding`, so
 * the renderer can show a "warming up" hint instead of an empty result.
 * Failures are logged and surfaced as a rejected promise; the partial
 * index (if any) remains in memory so concurrent searches don't crash.
 */
export async function rebuildIndexFromChunks<C extends { id: number; text: string }>(
  name: string,
  dim: number,
  loadChunks: () => Promise<C[]>,
  embed: (chunks: C[]) => Promise<Array<{ id: number; vector: number[] }>>
): Promise<void> {
  // Drop any in-memory copy plus the on-disk artifact before rebuilding.
  // saveVectors will recreate both lazily as embeddings arrive.
  indices.delete(name)
  unlinkBrokenIndex(name, 'rebuilding from source chunks')

  rebuilding.add(name)
  try {
    const chunks = await loadChunks()
    if (chunks.length === 0) return

    // Batch the embed call. We pass the whole list to the supplied
    // embedder which is expected to handle its own batching (see
    // generateEmbeddings: BATCH_SIZE = 32). This keeps the surface area
    // small and matches how the indexer already calls embed today.
    const vectors = await embed(chunks)
    if (vectors.length > 0) {
      saveVectors(name, dim, vectors)
    }
  } finally {
    rebuilding.delete(name)
  }
}

/**
 * Delete the index for `name`, removing both the in-memory cache and the
 * persisted file on disk.
 */
/**
 * Generate embeddings for text inputs using the local sentence-transformers model.
 * Re-exported from the embeddings module for convenience.
 */
export { generateEmbeddings } from './embeddings.js'

/**
 * Embed a single text string and return the embedding vector.
 */
export async function embedText(text: string): Promise<number[]> {
  const { generateEmbeddings: embed } = await import('./embeddings.js')
  const results = await embed([{ text, metadata: { id: 0, pageNumber: 0, bookId: 0 } }])
  return results[0]?.embedding ?? []
}

export function deleteIndex(name: string): void {
  indices.delete(name)
  rebuilding.delete(name)

  const filePath = indexPath(name)
  if (existsSync(filePath)) {
    unlinkSync(filePath)
  }
}

/**
 * Reset all module state. Test-only — used by `_resetForTesting` in
 * `index.test.ts` so each test starts from a clean slate without having
 * to reload the module via vi.resetModules().
 */
export function _resetForTesting(): void {
  indices.clear()
  rebuilding.clear()
  storageDir = ''
  HierarchicalNSW = null
}

/**
 * Test-only: inject a mock HierarchicalNSW constructor so unit tests can
 * exercise the recovery paths without the native `hnswlib-node` binding
 * being installed for the current Node ABI. The renderer + main process
 * still call `requireHnsw()` in production.
 */
export function _setHnswForTesting(ctor: HierarchicalNSWType | null): void {
  HierarchicalNSW = ctor
}
