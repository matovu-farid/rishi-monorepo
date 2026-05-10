import { describe, it, expect, vi } from 'vitest'
import Database from 'better-sqlite3'
import { runMigrations } from '../migrations.js'
import { _getBookOutlineWithDb } from '../queries.js'

vi.mock('electron', () => ({
  app: { on: () => {}, getPath: () => '/tmp' },
  ipcMain: { handle: () => {} }
}))

describe('getBookOutline against the real migration', () => {
  it('does not throw on a freshly migrated DB', () => {
    const db = new Database(':memory:')
    runMigrations(db)
    // Insert a book row matching the real schema
    const result = db
      .prepare(
        `INSERT INTO books (kind, cover, title, author, publisher, filepath, location, cover_kind, format, sync_version, is_dirty, is_deleted)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run('epub', Buffer.alloc(0), 'Test Book', 'Author', '', '/tmp/test.epub', '', 'png', 'epub', 0, 1, 0)
    const bookId = result.lastInsertRowid as number
    // Should not throw — even if no chunks/chapters yet
    expect(() => _getBookOutlineWithDb(db, bookId)).not.toThrow()
  })

  it('returns empty chapters when chunk_data has no chapter column', () => {
    const db = new Database(':memory:')
    runMigrations(db)
    const result = db
      .prepare(
        `INSERT INTO books (kind, cover, title, author, publisher, filepath, location, cover_kind, format, sync_version, is_dirty, is_deleted)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run('epub', Buffer.alloc(0), 'Test Book', 'Author', '', '/tmp/test.epub', '', 'png', 'epub', 0, 1, 0)
    const bookId = result.lastInsertRowid as number
    const outline = _getBookOutlineWithDb(db, bookId)
    expect(outline.title).toBe('Test Book')
    expect(outline.author).toBe('Author')
    expect(outline.chapters).toEqual([])
  })
})
