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
import { paragraphsForPage } from '@/lib/pdf/paragraphs-from-db'

describe('paragraphsForPage', () => {
  beforeEach(() => {
    rawDb.execSync('DELETE FROM book_paragraphs')
    rawDb.execSync('DELETE FROM books')
    runMigrations(rawDb, 1, migrations)
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted)
         VALUES ('b1', 't', 'a', '/tmp/a.pdf', 'pdf', 0, 0, 1, 0)`,
    )
    rawDb.execSync(
      `INSERT INTO book_paragraphs (book_id, page_number, paragraph_index, text)
         VALUES ('b1', 1, '10000', 'First paragraph.'),
                ('b1', 1, '10001', 'Second paragraph.'),
                ('b1', 2, '20000', 'Other page.')`,
    )
  })

  it('returns paragraphs for the requested page in {index,text} shape', () => {
    const result = paragraphsForPage('b1', 1)
    expect(result).toEqual([
      { index: '10000', text: 'First paragraph.' },
      { index: '10001', text: 'Second paragraph.' },
    ])
  })

  it('returns empty array for a page with no extracted text', () => {
    expect(paragraphsForPage('b1', 99)).toEqual([])
  })
})
