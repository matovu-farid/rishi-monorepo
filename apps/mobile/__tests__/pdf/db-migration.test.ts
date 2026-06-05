/**
 * Task 1 — Drizzle migration v1: book_pages / book_words / book_paragraphs
 *
 * Tests that the v1 migration:
 *   - creates the three PDF text-cache tables
 *   - adds the four extraction-status columns on `books`
 *   - enforces composite PKs
 *   - is idempotent (safe to run twice)
 *
 * Uses better-sqlite3 (a real SQLite engine that runs in Node) instead of
 * expo-sqlite so tests exercise actual SQLite semantics, not a fake.
 */

import Database from 'better-sqlite3'

// ─── Mock expo-sqlite before any @/lib/db import ─────────────────────────────
// db.ts calls openDatabaseSync at module level so we must mock before import.
jest.mock('expo-sqlite', () => ({
  openDatabaseSync: jest.fn(() => makeSqliteAdapter()),
}))

jest.mock('drizzle-orm/expo-sqlite', () => ({
  drizzle: jest.fn(() => ({})),
}))

jest.mock('@rishi/shared/schema', () => ({
  books: {},
  highlights: {},
  bookmarks: {},
  conversations: {},
  messages: {},
  syncMeta: {},
  syncState: {},
}))

function makeSqliteAdapter() {
  const db = new Database(':memory:')
  return {
    execSync(sql: string) { db.exec(sql) },
    getAllSync<T>(sql: string): T[] { return db.prepare(sql).all() as T[] },
    getFirstSync<T>(sql: string): T | undefined { return db.prepare(sql).get() as T | undefined },
  }
}

import { runMigrations, migrations } from '@/lib/db'

describe('schema migration v1 — PDF text cache', () => {
  /**
   * Each test gets its own isolated in-memory database with the `books`
   * table pre-created to mirror the state of a real device that has
   * already run the bootstrap block in lib/db.ts.
   */
  function freshDb() {
    const db = makeSqliteAdapter()
    db.execSync(
      `CREATE TABLE books (id TEXT PRIMARY KEY, file_path TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0)`,
    )
    return db
  }

  it('creates book_pages, book_words, book_paragraphs', () => {
    const db = freshDb()
    runMigrations(db, 1, migrations)

    const tables = db
      .getAllSync<{ name: string }>(`SELECT name FROM sqlite_master WHERE type='table'`)
      .map((r) => r.name)

    expect(tables).toEqual(expect.arrayContaining(['book_pages', 'book_words', 'book_paragraphs']))
  })

  it('adds extraction_status, extracted_pages, total_pages, extraction_error columns on books', () => {
    const db = freshDb()
    runMigrations(db, 1, migrations)

    const cols = db
      .getAllSync<{ name: string }>(`PRAGMA table_info(books)`)
      .map((r) => r.name)

    expect(cols).toEqual(
      expect.arrayContaining([
        'extraction_status',
        'extracted_pages',
        'total_pages',
        'extraction_error',
      ]),
    )
  })

  it('book_pages PK is (book_id, page_number)', () => {
    const db = freshDb()
    runMigrations(db, 1, migrations)

    db.execSync(
      `INSERT INTO book_pages (book_id, page_number, text, width_pts, height_pts, indexed_at) VALUES ('b', 1, 'a', 1.0, 1.0, 0)`,
    )
    expect(() =>
      db.execSync(
        `INSERT INTO book_pages (book_id, page_number, text, width_pts, height_pts, indexed_at) VALUES ('b', 1, 'b', 1.0, 1.0, 0)`,
      ),
    ).toThrow(/UNIQUE|PRIMARY/)
  })

  it('book_paragraphs PK is (book_id, page_number, paragraph_index)', () => {
    const db = freshDb()
    runMigrations(db, 1, migrations)
    db.execSync(
      `INSERT INTO book_paragraphs (book_id, page_number, paragraph_index, text) VALUES ('b', 1, '0', 'a')`,
    )
    // Same paragraph_index on a different page is allowed (PK includes page_number now).
    expect(() =>
      db.execSync(
        `INSERT INTO book_paragraphs (book_id, page_number, paragraph_index, text) VALUES ('b', 2, '0', 'b')`,
      ),
    ).not.toThrow()
    // Same (book_id, page_number, paragraph_index) collides.
    expect(() =>
      db.execSync(
        `INSERT INTO book_paragraphs (book_id, page_number, paragraph_index, text) VALUES ('b', 1, '0', 'c')`,
      ),
    ).toThrow(/UNIQUE|PRIMARY/)
  })

  it('migration is idempotent — running twice does not throw', () => {
    const db = freshDb()
    runMigrations(db, 1, migrations)
    expect(() => runMigrations(db, 1, migrations)).not.toThrow()
  })
})
