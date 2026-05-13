import { describe, it, expect, beforeEach, vi } from 'vitest'
import Database from 'better-sqlite3'

// Mock the electron module so queries.ts can be imported in the vitest env.
vi.mock('electron', () => ({
  app: {
    on: vi.fn(),
    getPath: vi.fn().mockReturnValue('/tmp/test')
  },
  ipcMain: {
    handle: vi.fn()
  }
}))

function setupDb(): Database.Database {
  const sqlite = new Database(':memory:')
  sqlite.exec(`
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      is_deleted INTEGER NOT NULL DEFAULT 0
    );
  `)
  return sqlite
}

describe('listRecentBooks', () => {
  let db: Database.Database

  beforeEach(() => {
    db = setupDb()
  })

  it('returns most-recent books first (highest id first), capped at limit', async () => {
    db.exec(`
      INSERT INTO books (title) VALUES ('First');
      INSERT INTO books (title) VALUES ('Second');
      INSERT INTO books (title) VALUES ('Third');
    `)
    const { _listRecentBooksWithDb } = await import('../queries.js')
    const recent = _listRecentBooksWithDb(db, 10)
    expect(recent.map((r) => r.title)).toEqual(['Third', 'Second', 'First'])
    expect(recent[0].bookId).toBeGreaterThan(0)
  })

  it('honors the limit', async () => {
    db.exec(`
      INSERT INTO books (title) VALUES ('A');
      INSERT INTO books (title) VALUES ('B');
      INSERT INTO books (title) VALUES ('C');
    `)
    const { _listRecentBooksWithDb } = await import('../queries.js')
    const recent = _listRecentBooksWithDb(db, 2)
    expect(recent.map((r) => r.title)).toEqual(['C', 'B'])
  })

  it('excludes soft-deleted books', async () => {
    db.exec(`
      INSERT INTO books (title, is_deleted) VALUES ('Alive 1', 0);
      INSERT INTO books (title, is_deleted) VALUES ('Dead', 1);
      INSERT INTO books (title, is_deleted) VALUES ('Alive 2', 0);
    `)
    const { _listRecentBooksWithDb } = await import('../queries.js')
    const recent = _listRecentBooksWithDb(db, 10)
    expect(recent.map((r) => r.title)).toEqual(['Alive 2', 'Alive 1'])
  })
})
