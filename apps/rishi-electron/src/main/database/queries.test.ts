import { describe, it, expect, beforeEach, vi } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import type { Database } from 'better-sqlite3'

// queries.ts → ./index.js → `import { app } from 'electron'` and `app.on(...)`
// at module top-level. Stub electron so the import doesn't crash under vitest.
vi.mock('electron', () => ({
  app: { on: () => {}, getPath: () => '/tmp' }
}))

import {
  _findBookByHashWithDb,
  _getBookFilepathsWithDb,
  _updateBookLastParagraphWithDb,
  _getBookByIdWithDb,
  _getAllBooksWithDb,
  _getCoverWithDb
} from './queries'
import { runMigrations } from './migrations'

const SCHEMA = `
  CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT, cover BLOB, title TEXT, author TEXT, publisher TEXT,
    filepath TEXT, location TEXT, cover_kind TEXT, version INTEGER,
    sync_id TEXT, file_hash TEXT, file_r2_key TEXT, cover_r2_key TEXT,
    file_size INTEGER DEFAULT 0,
    format TEXT, current_cfi TEXT, current_page INTEGER, user_id TEXT,
    sync_version INTEGER, is_dirty INTEGER, is_deleted INTEGER DEFAULT 0,
    last_paragraph TEXT
  )
`

function makeDb(): Database {
  const db = new BetterSqlite3(':memory:')
  // better-sqlite3 multi-statement DDL goes through Database#exec.

  ;(db as any).exec(SCHEMA)
  return db
}

function insert(
  db: Database,
  row: Partial<{
    filepath: string
    file_hash: string | null
    is_deleted: number
    title: string
  }>
): number {
  const info = db
    .prepare(
      `INSERT INTO books (filepath, file_hash, is_deleted, title, kind, cover, author,
       publisher, location, cover_kind, version, format, sync_version, is_dirty)
     VALUES (@filepath, @file_hash, @is_deleted, @title, 'epub', x'', '', '', '1', 'png',
       0, 'epub', 0, 0)`
    )
    .run({
      filepath: row.filepath ?? '/books/x.epub',
      file_hash: row.file_hash ?? null,
      is_deleted: row.is_deleted ?? 0,
      title: row.title ?? 'X'
    })
  return Number(info.lastInsertRowid)
}

describe('_findBookByHashWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns the book when a non-deleted row has the matching file_hash', () => {
    const id = insert(db, { file_hash: 'abc123', title: 'Found' })
    const result = _findBookByHashWithDb(db, 'abc123')
    expect(result?.id).toBe(id)
    expect(result?.title).toBe('Found')
  })

  it('returns undefined when no row matches', () => {
    insert(db, { file_hash: 'other' })
    expect(_findBookByHashWithDb(db, 'missing')).toBeUndefined()
  })

  it('skips soft-deleted rows even if their hash matches', () => {
    insert(db, { file_hash: 'abc123', is_deleted: 1 })
    expect(_findBookByHashWithDb(db, 'abc123')).toBeUndefined()
  })

  it('does not match rows with NULL file_hash for any non-empty hash query', () => {
    // Defensive: pre-backfill rows must never be returned by hash lookup.
    insert(db, { file_hash: null })
    expect(_findBookByHashWithDb(db, '')).toBeUndefined()
    expect(_findBookByHashWithDb(db, 'anything')).toBeUndefined()
  })
})

describe('_getBookFilepathsWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns filepaths of all non-deleted books', () => {
    insert(db, { filepath: '/books/a.epub' })
    insert(db, { filepath: '/books/b.pdf' })
    insert(db, { filepath: '/books/c.epub', is_deleted: 1 })
    expect(_getBookFilepathsWithDb(db).sort()).toEqual(['/books/a.epub', '/books/b.pdf'])
  })

  it('filters out empty-string filepaths', () => {
    insert(db, { filepath: '/books/a.epub' })
    insert(db, { filepath: '' })
    expect(_getBookFilepathsWithDb(db)).toEqual(['/books/a.epub'])
  })

  it('returns an empty array when no books exist', () => {
    expect(_getBookFilepathsWithDb(db)).toEqual([])
  })
})

describe('_updateBookLastParagraphWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('writes the value to the last_paragraph column', () => {
    const id = insert(db, {})
    _updateBookLastParagraphWithDb(db, id, 'epubcfi(/6/4!/2)')
    const row = db.prepare('SELECT last_paragraph FROM books WHERE id = ?').get(id) as {
      last_paragraph: string | null
    }
    expect(row.last_paragraph).toBe('epubcfi(/6/4!/2)')
  })

  it('accepts null to clear the column', () => {
    const id = insert(db, {})
    _updateBookLastParagraphWithDb(db, id, 'pdf-3-7')
    _updateBookLastParagraphWithDb(db, id, null)
    const row = db.prepare('SELECT last_paragraph FROM books WHERE id = ?').get(id) as {
      last_paragraph: string | null
    }
    expect(row.last_paragraph).toBeNull()
  })

  it('is a no-op for a missing book id', () => {
    expect(() => _updateBookLastParagraphWithDb(db, 999, 'x')).not.toThrow()
  })
})

describe('_getBookByIdWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns lastParagraph as null when never set', () => {
    const id = insert(db, {})
    const book = _getBookByIdWithDb(db, id)
    expect(book?.lastParagraph).toBeNull()
  })

  it('returns lastParagraph after it has been written', () => {
    const id = insert(db, {})
    _updateBookLastParagraphWithDb(db, id, 'azw3-2-15')
    const book = _getBookByIdWithDb(db, id)
    expect(book?.lastParagraph).toBe('azw3-2-15')
  })
})

// ---------------------------------------------------------------------------
// Cover BLOB is now lazy-loaded — `_getAllBooksWithDb` must NOT pull the
// raw `cover` column over IPC, and `_getCoverWithDb` exposes the BLOB on
// demand. See issue #190.
// ---------------------------------------------------------------------------

/** Insert a row with a known cover BLOB so we can assert lazy-load behavior. */
function insertWithCover(db: Database, cover: Buffer, title = 'Cover Book'): number {
  const info = db
    .prepare(
      `INSERT INTO books (filepath, file_hash, is_deleted, title, kind, cover, author,
       publisher, location, cover_kind, version, format, sync_version, is_dirty)
     VALUES (@filepath, @file_hash, @is_deleted, @title, 'epub', @cover, '', '', '1', 'png',
       0, 'epub', 0, 0)`
    )
    .run({
      filepath: '/books/cover.epub',
      file_hash: null,
      is_deleted: 0,
      title,
      cover
    })
  return Number(info.lastInsertRowid)
}

describe('_getAllBooksWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns books with an empty cover array — the BLOB is lazy-loaded via getCover', () => {
    insertWithCover(db, Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]), 'A')
    insertWithCover(db, Buffer.from([0xff, 0xd8, 0xff, 0xe0]), 'B')

    const books = _getAllBooksWithDb(db)
    expect(books.length).toBe(2)
    for (const book of books) {
      expect(Array.isArray(book.cover)).toBe(true)
      expect(book.cover.length).toBe(0)
    }
  })

  it('still populates all non-cover metadata (title, author, coverKind, etc.)', () => {
    const id = insertWithCover(db, Buffer.from([1, 2, 3]), 'Metadata Check')
    const books = _getAllBooksWithDb(db)
    const found = books.find((b) => b.id === id)
    expect(found?.title).toBe('Metadata Check')
    expect(found?.coverKind).toBe('png')
    expect(found?.format).toBe('epub')
  })

  it('skips soft-deleted books (parity with the old getAllBooks)', () => {
    insertWithCover(db, Buffer.alloc(0), 'Visible')
    insert(db, { is_deleted: 1, title: 'Hidden' })
    const books = _getAllBooksWithDb(db)
    expect(books.map((b) => b.title)).toEqual(['Visible'])
  })
})

describe('_getCoverWithDb', () => {
  let db: Database
  beforeEach(() => {
    db = makeDb()
  })

  it('returns the raw cover bytes for a known book id', () => {
    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    const id = insertWithCover(db, bytes)
    const cover = _getCoverWithDb(db, id)
    expect(cover).not.toBeNull()
    expect(Array.from(cover!)).toEqual(Array.from(bytes))
  })

  it('returns null for an unknown book id', () => {
    expect(_getCoverWithDb(db, 9999)).toBeNull()
  })

  it('returns an empty array (not null) when the book has no cover stored', () => {
    const id = insertWithCover(db, Buffer.alloc(0))
    const cover = _getCoverWithDb(db, id)
    expect(cover).not.toBeNull()
    expect(cover!.length).toBe(0)
  })
})

// ---------------------------------------------------------------------------
// Sharing-provenance columns on `books` (Plan 2 Task 22).
//
// P2P-received books carry three nullable columns that local-only books leave
// NULL. The migration test exercises `runMigrations` against a clean
// :memory: DB so we cover the actual migration path, not just the inline
// SCHEMA constant used by the other suites.
// ---------------------------------------------------------------------------
describe('books sharing-provenance columns (Task 22)', () => {
  function makeMigratedDb(): Database {
    const db = new BetterSqlite3(':memory:')
    runMigrations(db)
    return db
  }

  it('migration adds source / received_from_user_id / received_at columns', () => {
    const db = makeMigratedDb()
    const cols = db.prepare(`PRAGMA table_info(books)`).all() as Array<{ name: string }>
    const names = cols.map((c) => c.name)
    expect(names).toContain('source')
    expect(names).toContain('received_from_user_id')
    expect(names).toContain('received_at')
  })

  it('source column accepts the shared-session sentinel', () => {
    const db = makeMigratedDb()
    db.prepare(
      `INSERT INTO books (kind, cover, title, filepath, source, received_from_user_id, received_at)
       VALUES ('epub', x'00', 'T', '/p.epub', 'shared-session', 'u_b', 1700000000000)`
    ).run()
    const row = db
      .prepare(`SELECT source, received_from_user_id, received_at FROM books WHERE title = 'T'`)
      .get() as { source: string; received_from_user_id: string; received_at: number }
    expect(row.source).toBe('shared-session')
    expect(row.received_from_user_id).toBe('u_b')
    expect(row.received_at).toBe(1700000000000)
  })
})
