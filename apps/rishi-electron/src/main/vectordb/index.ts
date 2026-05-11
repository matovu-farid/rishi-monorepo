import { app } from 'electron'
import { join } from 'path'
import { mkdirSync, existsSync, unlinkSync } from 'fs'

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
type HierarchicalNSWType = typeof import('hnswlib-node').HierarchicalNSW

let HierarchicalNSW: HierarchicalNSWType | null = null

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

/** Directory where `.hnsw` index files are persisted. */
let storageDir = ''

/** In-memory cache of loaded HNSW indices, keyed by name. */
const indices = new Map<string, IndexEntry>()

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
    const mod = require('hnswlib-node') as typeof import('hnswlib-node')
    HierarchicalNSW = mod.HierarchicalNSW
    return HierarchicalNSW
  } catch (err) {
    throw new Error(
      `hnswlib-node is not available on this platform. ` +
        `Vector search will be unavailable. ` +
        `Original error: ${err instanceof Error ? err.message : String(err)}`
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
 * Load an existing index from disk, or return `undefined` if the file does
 * not exist.
 */
function loadIndexFromDisk(name: string, dim: number): IndexEntry | undefined {
  const filePath = indexPath(name)
  if (!existsSync(filePath)) return undefined

  const HNSW = requireHnsw()
  const index = new HNSW('cosine', dim)
  // 2nd arg `allowReplaceDeleted` must match what createIndex sets so
  // addPoint(..., replaceDeleted=true) works for indices loaded from disk.
  index.readIndexSync(filePath, true)
  index.setEf(DEFAULT_EF_SEARCH)

  const count = index.getCurrentCount()
  const maxElements = index.getMaxElements()

  return { index, dim, count, maxElements }
}

/**
 * Retrieve an IndexEntry from the in-memory cache, loading from disk when
 * necessary. Returns `undefined` when no persisted index exists.
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
export async function saveVectors(
  name: string,
  dim: number = DEFAULT_DIM,
  vectors: Array<{ id: number; vector: number[] }>
): Promise<void> {
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
 *          first). Returns an empty array when the index does not exist or
 *          contains no vectors.
 */
export async function searchVectors(
  name: string,
  query: number[],
  dim: number = DEFAULT_DIM,
  k: number = 5
): Promise<Array<{ id: number; distance: number }>> {
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

export async function deleteIndex(name: string): Promise<void> {
  indices.delete(name)

  const filePath = indexPath(name)
  if (existsSync(filePath)) {
    unlinkSync(filePath)
  }
}
