import { rawDb } from '@/lib/db'

/**
 * Load the sqlite-vec extension.
 * Requires withSQLiteVecExtension: true in app.json expo-sqlite plugin config.
 */
export function initVectorExtension(): void {
  rawDb.loadExtensionSync('vec0')
}

/**
 * Create the chunks metadata table and chunk_vectors vec0 virtual table.
 * Safe to call multiple times (uses IF NOT EXISTS).
 */
export function ensureChunkTables(): void {
  rawDb.execSync(`
    CREATE TABLE IF NOT EXISTS chunks (
      id TEXT PRIMARY KEY,
      book_id TEXT NOT NULL,
      chunk_index INTEGER NOT NULL,
      text TEXT NOT NULL,
      chapter TEXT,
      created_at INTEGER NOT NULL
    )
  `)
  rawDb.execSync(`
    CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vectors
    USING vec0(embedding float[384])
  `)
}

/**
 * Insert a text chunk and its embedding vector.
 *
 * @param chunkId - UUID for the chunk
 * @param bookId - Book this chunk belongs to
 * @param chunkIndex - Sequential position in the book
 * @param text - Chunk text content
 * @param chapter - Chapter label or null
 * @param embedding - 384-dimensional float vector
 */
export function insertChunkWithVector(
  chunkId: string,
  bookId: string,
  chunkIndex: number,
  text: string,
  chapter: string | null,
  embedding: number[]
): void {
  const result = rawDb.runSync(
    'INSERT INTO chunks (id, book_id, chunk_index, text, chapter, created_at) VALUES (?, ?, ?, ?, ?, ?)',
    [chunkId, bookId, chunkIndex, text, chapter, Date.now()]
  )
  rawDb.runSync('INSERT INTO chunk_vectors (rowid, embedding) VALUES (?, ?)', [
    result.lastInsertRowId,
    JSON.stringify(embedding),
  ])
}

/**
 * Search for chunks similar to a query embedding using KNN.
 *
 * @param bookId - Filter results to this book
 * @param queryEmbedding - 384-dimensional query vector
 * @param limit - Maximum results to return (default 5)
 * @returns Chunks ordered by distance (ascending)
 */
export function searchSimilarChunks(
  bookId: string,
  queryEmbedding: number[],
  limit: number = 5
): Array<{
  id: string
  text: string
  distance: number
  chapter: string | null
  chunkIndex: number
}> {
  return rawDb.getAllSync(
    `SELECT c.id, c.text, c.chapter, c.chunk_index as chunkIndex, v.distance
     FROM chunk_vectors v
     INNER JOIN chunks c ON c.rowid = v.rowid
     WHERE v.embedding MATCH ?
       AND c.book_id = ?
     ORDER BY v.distance
     LIMIT ?`,
    [JSON.stringify(queryEmbedding), bookId, limit]
  ) as any
}

/**
 * Check whether a book already has embedded chunks.
 */
export function isBookEmbedded(bookId: string): boolean {
  const rows = rawDb.getAllSync('SELECT 1 FROM chunks WHERE book_id = ? LIMIT 1', [bookId])
  return rows.length > 0
}

/**
 * Delete all chunks and vectors for a book (e.g., before re-embedding).
 */
export function deleteBookChunks(bookId: string): void {
  rawDb.execSync(
    `DELETE FROM chunk_vectors WHERE rowid IN (SELECT rowid FROM chunks WHERE book_id = '${bookId}')`
  )
  rawDb.execSync(`DELETE FROM chunks WHERE book_id = '${bookId}'`)
}
