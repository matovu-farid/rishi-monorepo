/**
 * Task 8 — JS extraction runner: queue + chunking + progress events
 *
 * Uses better-sqlite3 (real SQLite in Node) via the shared makeSqliteAdapter
 * helper. The jest.mock calls must stay at the top of this file so Jest
 * hoisting picks them up before any @/lib/db import.
 */

import Database from 'better-sqlite3'

// ─── Mock expo-sqlite before any @/lib/db import ─────────────────────────────
jest.mock('expo-sqlite', () => {
  // Inline factory — Jest hoists this block, so no imports from outer scope.
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
import { __mockState, type PageData } from 'rishi-pdf-extractor'
import { extractionEvents } from '@/lib/pdf/extraction-events'
import { enqueueExtraction, waitForIdle, __resetRunnerForTests } from '@/lib/pdf/extraction-runner'

function makePage(n: number): PageData {
  return {
    pageNumber: n,
    widthPts: 612, heightPts: 792,
    paragraphs: [{ index: `${n * 10000}`, text: `page ${n} text` }],
    words: [{ idx: 0, text: `word${n}`, x: 0, y: 0, w: 10, h: 10 }],
  }
}

describe('extraction-runner', () => {
  beforeEach(() => {
    extractionEvents.__resetForTests()
    __resetRunnerForTests()
    rawDb.execSync('DELETE FROM book_pages')
    rawDb.execSync('DELETE FROM book_words')
    rawDb.execSync('DELETE FROM book_paragraphs')
    rawDb.execSync('DELETE FROM books')
    runMigrations(rawDb, 1, migrations)
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted)
         VALUES ('b1', 't', 'a', '/tmp/a.pdf', 'pdf', 0, 0, 1, 0)`,
    )
    __mockState.pageCount = 3
    __mockState.extractPage = async (_path, n) => makePage(n)
  })

  it('inserts book_pages, book_words, book_paragraphs for every page', async () => {
    await enqueueExtraction({ bookId: 'b1', filePath: '/tmp/a.pdf', chunkSize: 25 })
    await waitForIdle()

    const pages = rawDb.getAllSync<{ page_number: number }>(
      `SELECT page_number FROM book_pages WHERE book_id='b1' ORDER BY page_number`,
    )
    expect(pages.map((r) => r.page_number)).toEqual([1, 2, 3])

    const words = rawDb.getAllSync<{ text: string }>(
      `SELECT text FROM book_words WHERE book_id='b1' AND page_number=1`,
    )
    expect(words).toEqual([{ text: 'word1' }])
  })

  it('updates books.extraction_status to extracted on success', async () => {
    await enqueueExtraction({ bookId: 'b1', filePath: '/tmp/a.pdf', chunkSize: 25 })
    await waitForIdle()

    const row = rawDb.getFirstSync<{ extraction_status: string; extracted_pages: number; total_pages: number }>(
      `SELECT extraction_status, extracted_pages, total_pages FROM books WHERE id='b1'`,
    )
    expect(row?.extraction_status).toBe('extracted')
    expect(row?.extracted_pages).toBe(3)
    expect(row?.total_pages).toBe(3)
  })

  it('emits progress events as chunks commit', async () => {
    __mockState.pageCount = 4
    const received: Array<{ extractedPages: number; status: string }> = []
    extractionEvents.on('progress', (e) =>
      received.push({ extractedPages: e.extractedPages, status: e.status }),
    )
    await enqueueExtraction({ bookId: 'b1', filePath: '/tmp/a.pdf', chunkSize: 2 })
    await waitForIdle()
    expect(received).toEqual([
      { extractedPages: 0, status: 'extracting' },
      { extractedPages: 2, status: 'extracting' },
      { extractedPages: 4, status: 'extracting' },
      { extractedPages: 4, status: 'extracted' },
    ])
  })

  it('records error status when extractPage throws', async () => {
    __mockState.extractPage = async () => { throw new Error('boom') }
    await enqueueExtraction({ bookId: 'b1', filePath: '/tmp/a.pdf', chunkSize: 25 })
    await waitForIdle()
    const row = rawDb.getFirstSync<{ extraction_status: string; extraction_error: string }>(
      `SELECT extraction_status, extraction_error FROM books WHERE id='b1'`,
    )
    expect(row?.extraction_status).toBe('error')
    expect(row?.extraction_error).toMatch(/boom/)
  })

  it('runs one book at a time even when multiple are enqueued', async () => {
    rawDb.execSync(
      `INSERT INTO books (id, title, author, file_path, format, created_at, updated_at, is_dirty, is_deleted)
         VALUES ('b2', 't', 'a', '/tmp/b.pdf', 'pdf', 0, 0, 1, 0)`,
    )
    const order: string[] = []
    __mockState.extractPage = async (path, n) => {
      order.push(`${path}:${n}`)
      return makePage(n)
    }
    await Promise.all([
      enqueueExtraction({ bookId: 'b1', filePath: '/tmp/a.pdf', chunkSize: 25 }),
      enqueueExtraction({ bookId: 'b2', filePath: '/tmp/b.pdf', chunkSize: 25 }),
    ])
    await waitForIdle()
    const firstA = order.indexOf('/tmp/a.pdf:1')
    const firstB = order.indexOf('/tmp/b.pdf:1')
    const lastA = order.lastIndexOf('/tmp/a.pdf:3')
    expect(firstA).toBeLessThan(firstB)
    expect(lastA).toBeLessThan(firstB)
  })
})
