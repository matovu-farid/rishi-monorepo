import type { Database } from 'better-sqlite3'
import { getDb } from './index.js'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface Book {
  id: number
  kind: string
  cover: number[]
  title: string
  author: string
  publisher: string
  filepath: string
  location: string
  coverKind: string
  version: number
  syncId: string | null
  fileHash: string | null
  fileR2Key: string | null
  coverR2Key: string | null
  format: string
  currentCfi: string | null
  currentPage: number | null
  userId: string | null
  syncVersion: number
  isDirty: number
  isDeleted: number
  lastParagraph: string | null
}

/**
 * Row read from `chunk_data` — `id` is always present (SQLite assigns the
 * PK on insert).
 */
export interface PageData {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

/**
 * Insert-shaped chunk row. `id` may be omitted (auto-assigned) or pinned
 * to a hash-derived value by the indexer. Matches the IPC
 * `ChunkDataInsertable` payload shape so `chunks:saveMany` callers don't
 * have to coerce nulls.
 */
export interface PageDataInsertable {
  id?: number | null
  pageNumber: number
  bookId: number
  data: string
}

export interface SearchResult {
  id: number
  pageNumber: number
  bookId: number
  snippet: string
  data: string
}

export interface ChunkText {
  id: number
  pageNumber: number
  bookId: number
  data: string
}

// ---------------------------------------------------------------------------
// Row ↔ Object mapping helpers
// ---------------------------------------------------------------------------

/** Map a raw DB row (snake_case) to a Book object (camelCase). */
function rowToBook(row: Record<string, unknown>): Book {
  // Convert cover from SQLite Buffer/Uint8Array to number[] for IPC serialization
  const rawCover = row.cover
  const cover =
    rawCover instanceof Buffer
      ? Array.from(rawCover)
      : rawCover instanceof Uint8Array
        ? Array.from(rawCover)
        : ((rawCover as number[] | null) ?? [])

  return {
    id: row.id as number,
    kind: row.kind as string,
    cover,
    title: row.title as string,
    author: row.author as string,
    publisher: row.publisher as string,
    filepath: row.filepath as string,
    location: row.location as string,
    coverKind: row.cover_kind as string,
    version: row.version as number,
    syncId: (row.sync_id as string | null) ?? null,
    fileHash: (row.file_hash as string | null) ?? null,
    fileR2Key: (row.file_r2_key as string | null) ?? null,
    coverR2Key: (row.cover_r2_key as string | null) ?? null,
    format: row.format as string,
    currentCfi: (row.current_cfi as string | null) ?? null,
    currentPage: (row.current_page as number | null) ?? null,
    userId: (row.user_id as string | null) ?? null,
    syncVersion: row.sync_version as number,
    isDirty: row.is_dirty as number,
    isDeleted: row.is_deleted as number,
    lastParagraph: (row.last_paragraph as string | null) ?? null
  }
}

// ---------------------------------------------------------------------------
// Book queries
// ---------------------------------------------------------------------------

/**
 * Return all non-deleted books.
 */
export function getAllBooks(): Book[] {
  const db = getDb()
  const rows = db.prepare('SELECT * FROM books WHERE is_deleted = 0').all()
  return rows.map((row) => rowToBook(row as Record<string, unknown>))
}

/**
 * Pure-SQL variant of `listRecentBooks` for unit testing without the global
 * `getDb()` wrapper. Returns the most-recently-touched non-deleted books,
 * most-recent first, capped at `limit`.
 *
 * The `books` schema has no created_at/updated_at — id is auto-increment,
 * so a higher id ≈ "more recent". When the schema lacks an `is_deleted`
 * column (older test DBs), we just skip that filter.
 */
export function _listRecentBooksWithDb(
  db: Database,
  limit: number
): { bookId: number; title: string }[] {
  // Detect whether is_deleted column exists; older test DBs may omit it.
  const cols = db.prepare<[], { name: string }>('PRAGMA table_info(books)').all() as Array<{
    name: string
  }>
  const hasIsDeleted = cols.some((c) => c.name === 'is_deleted')

  const sql = hasIsDeleted
    ? 'SELECT id as bookId, title FROM books WHERE COALESCE(is_deleted, 0) = 0 ORDER BY id DESC LIMIT ?'
    : 'SELECT id as bookId, title FROM books ORDER BY id DESC LIMIT ?'

  return db.prepare(sql).all(limit) as { bookId: number; title: string }[]
}

/**
 * Return the most-recently-touched non-deleted books, capped at `limit`.
 * Used to populate the File > Open Recent submenu in the native menu.
 */
export function listRecentBooks(limit: number): { bookId: number; title: string }[] {
  return _listRecentBooksWithDb(getDb(), limit)
}

/** Test-injectable variant of `getBook`. */
export function _getBookByIdWithDb(db: Database, id: number): Book | undefined {
  const row = db.prepare('SELECT * FROM books WHERE id = ?').get(id)
  return row ? rowToBook(row as Record<string, unknown>) : undefined
}

/**
 * Return a single book by id, or `undefined` if not found.
 */
export function getBook(id: number): Book | undefined {
  return _getBookByIdWithDb(getDb(), id)
}

/**
 * Pure-SQL variant of `findBookByHash` for unit testing. Returns the first
 * non-deleted book whose `file_hash` matches, or `undefined` if no row matches.
 * The `IS NOT NULL` guard ensures pre-backfill rows (file_hash IS NULL) are
 * never returned, so dedup is opt-in per-row.
 */
export function _findBookByHashWithDb(db: Database, hash: string): Book | undefined {
  const row = db
    .prepare(
      'SELECT * FROM books WHERE file_hash = ? AND file_hash IS NOT NULL AND COALESCE(is_deleted, 0) = 0 LIMIT 1'
    )
    .get(hash)
  return row ? rowToBook(row as Record<string, unknown>) : undefined
}

/**
 * Look up a book by SHA-256 file hash. Returns `undefined` when no row matches
 * or when the existing rows for that hash are all soft-deleted.
 */
export function findBookByHash(hash: string): Book | undefined {
  return _findBookByHashWithDb(getDb(), hash)
}

/**
 * Pure-SQL variant for testing. Returns non-empty filepaths of every
 * non-deleted book — used by the import wizard to filter discovered books
 * the user already has.
 */
export function _getBookFilepathsWithDb(db: Database): string[] {
  const rows = db
    .prepare('SELECT filepath FROM books WHERE COALESCE(is_deleted, 0) = 0')
    .all() as Array<{ filepath: string | null }>
  return rows.map((r) => r.filepath ?? '').filter((p) => p.length > 0)
}

/**
 * Return filepaths of every non-deleted book. Lightweight (no cover blobs)
 * — safe to pull across the IPC boundary on wizard open.
 */
export function getBookFilepaths(): string[] {
  return _getBookFilepathsWithDb(getDb())
}

/**
 * Insert-shape for `saveBook`. Mirrors the IPC `BookInsertable` payload —
 * `id` may be omitted (new book) or supplied (upsert by primary key), and
 * `cover` is the number[] form produced by the renderer (converted to a
 * Buffer here for SQLite's blob column).
 */
export interface BookSaveInput {
  id?: number | null
  kind?: string | null
  cover?: number[] | Buffer | null
  title?: string | null
  author?: string | null
  publisher?: string | null
  filepath?: string | null
  location?: string | null
  coverKind?: string | null
  version?: number | null
  syncId?: string | null
  fileHash?: string | null
  fileR2Key?: string | null
  coverR2Key?: string | null
  format?: string | null
  currentCfi?: string | null
  currentPage?: number | null
  userId?: string | null
  syncVersion?: number | null
  isDirty?: number | null
  isDeleted?: number | null
}

/**
 * Insert a new book or update an existing one (upsert on `id`).
 * Returns the full Book object (with generated id for inserts).
 * Accepts partial input with sensible defaults for missing fields.
 */
export function saveBook(input: BookSaveInput): Book {
  const db = getDb()

  // Normalize: convert number[] cover to Buffer for SQLite BLOB
  const rawCover = input.cover
  const cover = Array.isArray(rawCover) ? Buffer.from(rawCover) : (rawCover ?? Buffer.alloc(0))

  // Infer format from kind if not provided
  const kind = input.kind ?? 'epub'
  const format = input.format ?? kind

  const params = {
    kind,
    cover,
    title: input.title ?? '',
    author: input.author ?? '',
    publisher: input.publisher ?? '',
    filepath: input.filepath ?? '',
    location: input.location ?? '',
    coverKind: input.coverKind ?? 'png',
    version: input.version ?? 0,
    syncId: input.syncId ?? null,
    fileHash: input.fileHash ?? null,
    fileR2Key: input.fileR2Key ?? null,
    coverR2Key: input.coverR2Key ?? null,
    format,
    currentCfi: input.currentCfi ?? null,
    currentPage: input.currentPage ?? null,
    userId: input.userId ?? null,
    syncVersion: input.syncVersion ?? 0,
    isDirty: input.isDirty ?? 1,
    isDeleted: input.isDeleted ?? 0
  }

  const bookId = input.id ?? undefined

  if (bookId != null) {
    db.prepare(
      `
      UPDATE books SET
        kind = @kind, cover = @cover, title = @title, author = @author,
        publisher = @publisher, filepath = @filepath, location = @location,
        cover_kind = @coverKind, version = @version, sync_id = @syncId,
        file_hash = @fileHash, file_r2_key = @fileR2Key, cover_r2_key = @coverR2Key,
        format = @format, current_cfi = @currentCfi, current_page = @currentPage,
        user_id = @userId, sync_version = @syncVersion, is_dirty = @isDirty,
        is_deleted = @isDeleted
      WHERE id = @id
    `
    ).run({ ...params, id: bookId })
    const updated = getBook(bookId)
    if (!updated) {
      throw new Error(`saveBook: book ${bookId} disappeared after UPDATE`)
    }
    return updated
  }

  const info = db
    .prepare(
      `
    INSERT INTO books (
      kind, cover, title, author, publisher, filepath, location,
      cover_kind, version, sync_id, file_hash, file_r2_key,
      cover_r2_key, format, current_cfi, current_page, user_id,
      sync_version, is_dirty, is_deleted
    ) VALUES (
      @kind, @cover, @title, @author, @publisher, @filepath, @location,
      @coverKind, @version, @syncId, @fileHash, @fileR2Key,
      @coverR2Key, @format, @currentCfi, @currentPage, @userId,
      @syncVersion, @isDirty, @isDeleted
    )
  `
    )
    .run(params)
  const newId = Number(info.lastInsertRowid)
  const inserted = getBook(newId)
  if (!inserted) {
    throw new Error(`saveBook: failed to read back inserted book ${newId}`)
  }
  return inserted
}

/**
 * Soft-delete a book by setting is_deleted = 1 and is_dirty = 1.
 */
export function deleteBook(id: number): void {
  const db = getDb()
  db.prepare('UPDATE books SET is_deleted = 1, is_dirty = 1 WHERE id = ?').run(id)
}

/**
 * Hard-delete all chunk_data rows for a book. Chunks are local-only (not
 * sync-tracked), so removing them frees DB + FTS index space immediately.
 * Called from the books:delete IPC handler alongside the .hnsw cleanup.
 */
export function deleteChunksByBookId(bookId: number): void {
  _deleteChunksByBookIdWithDb(getDb(), bookId)
}

/** Test-only db-injectable variant; mirrors the _getBookOutlineWithDb pattern. */
export function _deleteChunksByBookIdWithDb(db: ReturnType<typeof getDb>, bookId: number): number {
  const result = db.prepare('DELETE FROM chunk_data WHERE book_id = ?').run(bookId)
  return result.changes
}

/**
 * Update only the cover blob for a book.
 */
export function updateBookCover(id: number, cover: number[] | Buffer): void {
  const db = getDb()
  const buf = Array.isArray(cover) ? Buffer.from(cover) : cover
  db.prepare("UPDATE books SET cover = ?, cover_kind = 'png', is_dirty = 1 WHERE id = ?").run(
    buf,
    id
  )
}

/**
 * Update the reading location for a book.
 * For epub: sets `current_cfi`.
 * For pdf and other page-based formats: sets `current_page`.
 */
export function updateBookLocation(id: number, location: string | number): void {
  const db = getDb()
  const book = getBook(id)
  if (!book) {
    throw new Error(`Book with id ${id} not found`)
  }

  // Always update the `location` column — this is what all reader components
  // read from via `book.location` when restoring position on re-open.
  // Also update the format-specific column for completeness.
  if (book.format === 'epub') {
    db.prepare('UPDATE books SET location = ?, current_cfi = ?, is_dirty = 1 WHERE id = ?').run(
      String(location),
      String(location),
      id
    )
  } else {
    db.prepare('UPDATE books SET location = ?, current_page = ?, is_dirty = 1 WHERE id = ?').run(
      String(location),
      Number(location),
      id
    )
  }
}

/**
 * Test-injectable variant. Updates the `last_paragraph` column for one book.
 * Pass `null` to clear it. No-op when the id doesn't match a row.
 */
export function _updateBookLastParagraphWithDb(
  db: Database,
  id: number,
  lastParagraph: string | null
): void {
  db.prepare('UPDATE books SET last_paragraph = ?, is_dirty = 1 WHERE id = ?').run(
    lastParagraph,
    id
  )
}

export function updateBookLastParagraph(id: number, lastParagraph: string | null): void {
  _updateBookLastParagraphWithDb(getDb(), id, lastParagraph)
}

// ---------------------------------------------------------------------------
// Chunk data (page text) queries
// ---------------------------------------------------------------------------

/**
 * Check whether any chunk_data rows exist for a given book.
 */
export function hasSavedEpubData(bookId: number): boolean {
  const db = getDb()
  const row = db
    .prepare('SELECT COUNT(*) as count FROM chunk_data WHERE book_id = ?')
    .get(bookId) as { count: number } | undefined
  return (row?.count ?? 0) > 0
}

/**
 * Bulk-insert page data rows inside a single transaction for performance.
 *
 * Honors `row.id` when supplied so callers (specifically the book-import
 * indexer) can pin chunk PKs to the hash-derived IDs produced by
 * `stringToNumberID(bookId-section-startCfi-endCfi)`. Those same IDs are
 * used as hnsw vector labels in saveVectors, so chunk_data.id and hnsw
 * labels must align for getTextFromVectorId lookups to resolve.
 *
 * If `row.id` is omitted, SQLite assigns an AUTOINCREMENT id (legacy path).
 *
 * Uses INSERT OR IGNORE: hash-derived IDs are deterministic by design, so a
 * collision means the row is already present (concurrent indexBook calls,
 * paragraphs that hash to the same value, or re-running a partially-failed
 * batch). Silently skipping is idempotent and correct — without OR IGNORE,
 * one duplicate would abort the whole transaction and leave the book
 * unindexed forever. FTS triggers fire on actual inserts only, so skipped
 * rows don't desync chunk_data_fts.
 */
export function savePageDataMany(pageData: PageDataInsertable[]): void {
  if (pageData.length === 0) return

  const db = getDb()
  const stmt = db.prepare(
    'INSERT OR IGNORE INTO chunk_data (id, page_number, book_id, data) VALUES (@id, @pageNumber, @bookId, @data)'
  )

  const insertMany = db.transaction((rows: PageDataInsertable[]) => {
    for (const row of rows) {
      stmt.run({
        id: row.id ?? null,
        pageNumber: row.pageNumber,
        bookId: row.bookId,
        data: row.data
      })
    }
  })

  insertMany(pageData)
}

/**
 * Return the set of page numbers already present in chunk_data for a book.
 * Used to skip re-extracting and re-embedding pages that have been indexed
 * already, e.g. across app restarts or after a partial run.
 */
export function getIndexedPageNumbers(bookId: number): number[] {
  const db = getDb()
  const rows = db
    .prepare('SELECT DISTINCT page_number FROM chunk_data WHERE book_id = ?')
    .all(bookId) as Array<Record<string, unknown>>
  return rows.map((row) => row.page_number as number)
}

/**
 * Return all chunk_data rows for a book, ordered by page number.
 */
export function getAllPageDataByBookId(bookId: number): PageData[] {
  const db = getDb()
  const rows = db
    .prepare(
      'SELECT id, page_number, book_id, data FROM chunk_data WHERE book_id = ? ORDER BY page_number'
    )
    .all(bookId) as Array<Record<string, unknown>>

  return rows.map((row) => ({
    id: row.id as number,
    pageNumber: row.page_number as number,
    bookId: row.book_id as number,
    data: row.data as string
  }))
}

/**
 * Full-text search across a book's chunk data using FTS5.
 * Returns matching rows with a highlighted snippet.
 */
export function searchBookText(query: string, bookId: number): SearchResult[] {
  const db = getDb()
  const rows = db
    .prepare(
      `
      SELECT
        cd.id,
        cd.page_number,
        cd.book_id,
        cd.data,
        snippet(chunk_data_fts, 0, '<mark>', '</mark>', '...', 40) AS snippet
      FROM chunk_data_fts
      JOIN chunk_data cd ON cd.id = chunk_data_fts.rowid
      WHERE chunk_data_fts MATCH ?
        AND cd.book_id = ?
      ORDER BY rank
      `
    )
    .all(query, bookId) as Array<Record<string, unknown>>

  return rows.map((row) => ({
    id: row.id as number,
    pageNumber: row.page_number as number,
    bookId: row.book_id as number,
    snippet: row.snippet as string,
    data: row.data as string
  }))
}

/**
 * Retrieve a single chunk's text by its row id (used by vector search).
 */
export function getTextFromVectorId(id: number): ChunkText | undefined {
  const db = getDb()
  const row = db
    .prepare('SELECT id, page_number, book_id, data FROM chunk_data WHERE id = ?')
    .get(id) as Record<string, unknown> | undefined

  if (!row) return undefined

  return {
    id: row.id as number,
    pageNumber: row.page_number as number,
    bookId: row.book_id as number,
    data: row.data as string
  }
}

// ---------------------------------------------------------------------------
// Book outline query
// ---------------------------------------------------------------------------

export interface BookOutline {
  title: string
  author: string | null
  chapters: string[]
}

/**
 * Pure SQL helper exposed for unit testing without the global drizzle wrapper.
 * Use `getBookOutline(bookId)` from production code.
 */
export function _getBookOutlineWithDb(sqlite: Database, bookId: number): BookOutline {
  const bookRow = sqlite
    .prepare<
      [number],
      { title: string; author: string | null }
    >('SELECT title, author FROM books WHERE id = ?')
    .get(bookId)
  if (!bookRow) {
    return { title: '', author: null, chapters: [] }
  }
  let chapters: string[] = []
  try {
    const chapterRows = sqlite
      .prepare<[number], { chapter: string }>(
        `SELECT chapter FROM chunk_data
         WHERE book_id = ? AND chapter IS NOT NULL AND chapter != ''
         GROUP BY chapter
         ORDER BY MIN(page_number)`
      )
      .all(bookId)
    chapters = chapterRows.map((r) => r.chapter)
  } catch {
    // chapter column doesn't exist in this DB version — return empty chapters.
    // Outline is now primarily populated via epubjs TOC in the renderer.
  }
  return {
    title: bookRow.title,
    author: bookRow.author ?? null,
    chapters
  }
}

export function getBookOutline(bookId: number): BookOutline {
  const sqlite = getDb()
  return _getBookOutlineWithDb(sqlite, bookId)
}
