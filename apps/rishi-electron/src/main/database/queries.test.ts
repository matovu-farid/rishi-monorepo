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
  _getBookByIdWithDb
} from './queries'

const SCHEMA = `
  CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT, cover BLOB, title TEXT, author TEXT, publisher TEXT,
    filepath TEXT, location TEXT, cover_kind TEXT, version INTEGER,
    sync_id TEXT, file_hash TEXT, file_r2_key TEXT, cover_r2_key TEXT,
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
