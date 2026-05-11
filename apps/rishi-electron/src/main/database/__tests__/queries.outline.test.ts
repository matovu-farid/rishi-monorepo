import { describe, it, expect, beforeEach, vi } from 'vitest'
import Database from 'better-sqlite3'

// Mock the electron module so queries.ts can be imported in the vitest environment
vi.mock('electron', () => ({
  app: {
    on: vi.fn(),
    getPath: vi.fn().mockReturnValue('/tmp/test')
  },
  ipcMain: {
    handle: vi.fn()
  }
}))

function setupDb() {
  const sqlite = new Database(':memory:')
  sqlite.exec(`
    CREATE TABLE books (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      author TEXT
    );
    CREATE TABLE chunk_data (
      id INTEGER PRIMARY KEY,
      book_id INTEGER NOT NULL,
      page_number INTEGER NOT NULL,
      data TEXT NOT NULL,
      chapter TEXT
    );
  `)
  return sqlite
}

describe('getBookOutline', () => {
  let db: Database.Database

  beforeEach(() => {
    db = setupDb()
  })

  it('returns title, author, and ordered chapters', async () => {
    db.exec(`
      INSERT INTO books (id, title, author) VALUES (1, 'The Pragmatic Programmer', 'Hunt and Thomas');
      INSERT INTO chunk_data (book_id, page_number, data, chapter) VALUES
        (1, 1, 'foo', 'Introduction'),
        (1, 2, 'bar', 'Introduction'),
        (1, 3, 'baz', 'Chapter 1'),
        (1, 4, 'qux', 'Chapter 2'),
        (1, 5, 'quux', 'Chapter 2');
    `)
    const { _getBookOutlineWithDb } = await import('../queries.js')
    const outline = _getBookOutlineWithDb(db, 1)
    expect(outline.title).toBe('The Pragmatic Programmer')
    expect(outline.author).toBe('Hunt and Thomas')
    expect(outline.chapters).toEqual(['Introduction', 'Chapter 1', 'Chapter 2'])
  })

  it('excludes null/empty chapters', async () => {
    db.exec(`
      INSERT INTO books (id, title) VALUES (1, 'Book');
      INSERT INTO chunk_data (book_id, page_number, data, chapter) VALUES
        (1, 1, 'x', NULL),
        (1, 2, 'y', ''),
        (1, 3, 'z', 'Real Chapter');
    `)
    const { _getBookOutlineWithDb } = await import('../queries.js')
    const outline = _getBookOutlineWithDb(db, 1)
    expect(outline.chapters).toEqual(['Real Chapter'])
  })

  it('returns null author when missing', async () => {
    db.exec(`INSERT INTO books (id, title) VALUES (1, 'Anon Book');`)
    const { _getBookOutlineWithDb } = await import('../queries.js')
    const outline = _getBookOutlineWithDb(db, 1)
    expect(outline.author).toBeNull()
  })
})
