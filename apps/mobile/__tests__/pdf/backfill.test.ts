/**
 * Task 10 — boot-time backfill of unextracted books
 *
 * Uses better-sqlite3 (real SQLite in Node) via the shared makeSqliteAdapter
 * helper. The jest.mock calls must stay at the top of this file so Jest
 * hoisting picks them up before any @/lib/db import.
 */

// ─── Mock expo-sqlite before any @/lib/db import ─────────────────────────────
jest.mock('expo-sqlite', () => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const Database = require('better-sqlite3')
  function makeSqliteAdapter() {
    const db = new Database(':memory:')
    return {
      execSync(sql: string) { db.exec(sql) },
      getAllSync<T>(sql: string): T[] { return db.prepare(sql).all() as T[] },
      getFirstSync<T>(sql: string): T | undefined { return db.prepare(sql).get() as T | undefined },
    }
  }
  return { openDatabaseSync: jest.fn(() => makeSqliteAdapter()) }
})

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

import { rawDb, runMigrations, migrations } from '@/lib/db'
import { __mockState } from 'rishi-pdf-extractor'
import { waitForIdle, __resetRunnerForTests } from '@/lib/pdf/extraction-runner'
import { backfillUnextractedBooks } from '@/lib/pdf/backfill'

describe('backfillUnextractedBooks', () => {
  beforeEach(() => {
    __resetRunnerForTests()
    rawDb.execSync('DELETE FROM book_pages')
    rawDb.execSync('DELETE FROM book_words')
    rawDb.execSync('DELETE FROM book_paragraphs')
    rawDb.execSync('DELETE FROM books')
    runMigrations(rawDb, 1, migrations)
    __mockState.pageCount = 1
    __mockState.extractPage = async (_p, n) => ({
      pageNumber: n, widthPts: 612, heightPts: 792,
      paragraphs: [{ index: `${n * 10000}`, text: 'x' }],
      words: [],
    })
  })

  it('enqueues PDF books whose extraction_status is NULL', async () => {
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted)
         VALUES ('old1', 't', 'a', '/tmp/o.pdf', 'pdf', 0, 0, 1, 0)`,
    )
    await backfillUnextractedBooks()
    await waitForIdle()
    const pages = rawDb.getAllSync(`SELECT * FROM book_pages WHERE book_id='old1'`)
    expect(pages).toHaveLength(1)
  })

  it('also enqueues books stuck in pending/extracting', async () => {
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted, extraction_status)
         VALUES ('stuck1', 't', 'a', '/tmp/s.pdf', 'pdf', 0, 0, 1, 0, 'extracting')`,
    )
    await backfillUnextractedBooks()
    await waitForIdle()
    const row = rawDb.getFirstSync<{ extraction_status: string }>(
      `SELECT extraction_status FROM books WHERE id='stuck1'`,
    )
    expect(row?.extraction_status).toBe('extracted')
  })

  it('does NOT enqueue books already extracted', async () => {
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted, extraction_status)
         VALUES ('done1', 't', 'a', '/tmp/d.pdf', 'pdf', 0, 0, 1, 0, 'extracted')`,
    )
    let calls = 0
    __mockState.extractPage = async () => { calls++; throw new Error('should not be called') }
    await backfillUnextractedBooks()
    await waitForIdle()
    expect(calls).toBe(0)
  })

  it('does NOT enqueue EPUBs', async () => {
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted)
         VALUES ('epub1', 't', 'a', '/tmp/e.epub', 'epub', 0, 0, 1, 0)`,
    )
    let calls = 0
    __mockState.extractPage = async () => { calls++; throw new Error('should not be called') }
    await backfillUnextractedBooks()
    await waitForIdle()
    expect(calls).toBe(0)
  })
})
