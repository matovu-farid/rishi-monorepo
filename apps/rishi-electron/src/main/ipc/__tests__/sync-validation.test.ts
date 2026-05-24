import { describe, it, expect, beforeEach, vi } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import type { Database } from 'better-sqlite3'
import { drizzle } from 'drizzle-orm/better-sqlite3'
import { eq } from 'drizzle-orm'
import * as schema from '../../database/schema.js'

// sync.ts imports preload/ipc-contract which pulls in `electron`. Stub it so
// the module loads under vitest (same pattern as queries.test.ts).
vi.mock('electron', () => ({
  ipcMain: { handle: () => {} },
  app: { on: () => {}, getPath: () => '/tmp' }
}))

import {
  _applyBookConflictWithDb,
  _applyHighlightConflictWithDb,
  _applyConversationConflictWithDb,
  _upsertBookWithDb,
  _markBooksCleanWithDb
} from '../sync.js'

const DDL_STATEMENTS = [
  `CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL DEFAULT 'epub',
    cover BLOB NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    publisher TEXT NOT NULL DEFAULT '',
    filepath TEXT NOT NULL DEFAULT '',
    location TEXT NOT NULL DEFAULT '',
    cover_kind TEXT NOT NULL DEFAULT 'png',
    version INTEGER NOT NULL DEFAULT 0,
    sync_id TEXT,
    file_hash TEXT,
    file_r2_key TEXT,
    cover_r2_key TEXT,
    file_size INTEGER NOT NULL DEFAULT 0,
    format TEXT NOT NULL DEFAULT 'epub',
    current_cfi TEXT,
    current_page INTEGER,
    user_id TEXT,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    last_paragraph TEXT
  )`,
  `CREATE TABLE highlights (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    format TEXT NOT NULL DEFAULT 'epub',
    cfi_range TEXT NOT NULL DEFAULT '',
    locator TEXT,
    text TEXT NOT NULL DEFAULT '',
    color TEXT NOT NULL DEFAULT 'yellow',
    note TEXT NOT NULL DEFAULT '',
    chapter TEXT,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at INTEGER,
    sync_id TEXT,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
  )`,
  `CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    user_id TEXT,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at INTEGER,
    sync_id TEXT,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
  )`
]

function makeDb(): { sqlite: Database; db: ReturnType<typeof drizzle<typeof schema>> } {
  const sqlite = new BetterSqlite3(':memory:')
  for (const stmt of DDL_STATEMENTS) sqlite.prepare(stmt).run()
  const db = drizzle(sqlite, { schema })
  return { sqlite, db }
}

function seedBook(
  sqlite: Database,
  syncId: string,
  overrides: Partial<{ title: string; author: string; format: string; is_dirty: number }> = {}
): void {
  sqlite
    .prepare(
      `INSERT INTO books (kind, cover, title, author, publisher, filepath, location, cover_kind,
       version, sync_id, format, sync_version, is_dirty, is_deleted, file_size)
       VALUES ('epub', x'', @title, @author, '', '', '', 'png', 0, @sync_id, @format, 0, @is_dirty, 0, 0)`
    )
    .run({
      title: overrides.title ?? 'Original Title',
      author: overrides.author ?? 'Original Author',
      sync_id: syncId,
      format: overrides.format ?? 'epub',
      is_dirty: overrides.is_dirty ?? 0
    })
}

// ---------------------------------------------------------------------------
// SYNC-VAL: malformed payload guards (#166)
// ---------------------------------------------------------------------------

describe('sync IPC validation (issue #166)', () => {
  let sqlite: Database
  let db: ReturnType<typeof drizzle<typeof schema>>

  beforeEach(() => {
    ;({ sqlite, db } = makeDb())
  })

  describe('_applyBookConflictWithDb', () => {
    it('refuses a payload whose id is not a string', () => {
      seedBook(sqlite, 'book-1')
      const malformed = { id: 123, title: null, isDeleted: 'yes' }
      expect(() => _applyBookConflictWithDb(db, malformed, 5)).not.toThrow()
      const row = db.select().from(schema.books).where(eq(schema.books.syncId, 'book-1')).get()
      // Original row must remain — invalid payload should be ignored.
      expect(row?.title).toBe('Original Title')
      expect(row?.author).toBe('Original Author')
      expect(row?.title).not.toBeNull()
    })

    it('coerces isDeleted to a number and never writes null into NOT NULL columns', () => {
      seedBook(sqlite, 'book-2')
      const payload = {
        id: 'book-2',
        title: 'Cloud Title',
        author: 'Cloud Author',
        format: 'epub',
        isDeleted: 'yes' // truthy non-bool
      }
      _applyBookConflictWithDb(db, payload, 7)
      const row = db.select().from(schema.books).where(eq(schema.books.syncId, 'book-2')).get()
      expect(row?.title).toBe('Cloud Title')
      expect(row?.author).toBe('Cloud Author')
      expect(typeof row?.isDeleted).toBe('number')
    })
  })

  describe('_applyHighlightConflictWithDb', () => {
    it('refuses malformed payload without writing garbage', () => {
      sqlite
        .prepare(
          `INSERT INTO highlights (id, book_id, text, color, cfi_range)
           VALUES ('hl-1', 'book-1', 'orig text', 'yellow', 'epubcfi(/6/4)')`
        )
        .run()
      const malformed = { id: 123, title: null, isDeleted: 'yes' }
      expect(() => _applyHighlightConflictWithDb(db, malformed, 5)).not.toThrow()
      const row = db
        .select()
        .from(schema.highlights)
        .where(eq(schema.highlights.id, 'hl-1'))
        .get()
      expect(row?.text).toBe('orig text')
    })
  })

  describe('_applyConversationConflictWithDb', () => {
    it('refuses malformed payload without writing garbage', () => {
      sqlite
        .prepare(
          `INSERT INTO conversations (id, book_id, title) VALUES ('conv-1', 'book-1', 'orig title')`
        )
        .run()
      const malformed = { id: 123, title: null, isDeleted: 'yes' }
      expect(() => _applyConversationConflictWithDb(db, malformed, 5)).not.toThrow()
      const row = db
        .select()
        .from(schema.conversations)
        .where(eq(schema.conversations.id, 'conv-1'))
        .get()
      expect(row?.title).toBe('orig title')
    })
  })

  describe('_upsertBookWithDb', () => {
    it('refuses a payload whose id is not a string (no insert, no crash)', () => {
      const before = db.select().from(schema.books).all().length
      expect(() =>
        _upsertBookWithDb(db, { id: 123, title: null, isDeleted: 'yes' })
      ).not.toThrow()
      const after = db.select().from(schema.books).all().length
      expect(after).toBe(before)
    })

    it('inserts coerced safe defaults when optional fields are missing', () => {
      _upsertBookWithDb(db, { id: 'remote-1' })
      const row = db.select().from(schema.books).where(eq(schema.books.syncId, 'remote-1')).get()
      expect(row).toBeDefined()
      expect(row?.title).toBeDefined()
      expect(row?.author).toBeDefined()
      expect(row?.format).toBeDefined()
    })

    // Regression: the pre-PR `_upsertBookWithDb` had `if (!syncId) return` on
    // an empty-string id. Mirror that semantic in the validator: id.min(1)
    // rejects the empty string so the row never lands in SQLite (#166).
    it('refuses a payload whose id is empty string (no insert, no crash)', () => {
      const before = db.select().from(schema.books).all().length
      expect(() => _upsertBookWithDb(db, { id: '' })).not.toThrow()
      const after = db.select().from(schema.books).all().length
      expect(after).toBe(before)
    })
  })
})

// ---------------------------------------------------------------------------
// SYNC-TX: multi-statement ops wrapped in db.transaction (#167)
// ---------------------------------------------------------------------------

describe('sync IPC transactions (issue #167)', () => {
  let sqlite: Database
  let db: ReturnType<typeof drizzle<typeof schema>>

  beforeEach(() => {
    ;({ sqlite, db } = makeDb())
  })

  it('_markBooksCleanWithDb wraps the loop in a single transaction', () => {
    seedBook(sqlite, 'book-a', { is_dirty: 1 })
    seedBook(sqlite, 'book-b', { is_dirty: 1 })
    seedBook(sqlite, 'book-c', { is_dirty: 1 })

    const txSpy = vi.spyOn(db, 'transaction')
    _markBooksCleanWithDb(db, ['book-a', 'book-b', 'book-c'], 9)
    expect(txSpy).toHaveBeenCalledTimes(1)

    const rows = db.select().from(schema.books).all()
    expect(rows.every((r) => r.isDirty === 0)).toBe(true)
    expect(rows.every((r) => r.syncVersion === 9)).toBe(true)
  })

  it('_upsertBookWithDb runs SELECT+INSERT/UPDATE inside a transaction', () => {
    const txSpy = vi.spyOn(db, 'transaction')
    _upsertBookWithDb(db, { id: 'remote-tx-1', title: 'T', author: 'A', format: 'epub' })
    expect(txSpy).toHaveBeenCalledTimes(1)
  })

  it('_applyBookConflictWithDb wraps the update in a transaction', () => {
    seedBook(sqlite, 'book-tx')
    const txSpy = vi.spyOn(db, 'transaction')
    _applyBookConflictWithDb(
      db,
      { id: 'book-tx', title: 'New', author: 'New', format: 'epub' },
      5
    )
    expect(txSpy).toHaveBeenCalledTimes(1)
  })
})
