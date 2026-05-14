import { describe, it, expect, beforeEach, vi } from 'vitest'
import Database from 'better-sqlite3'
import { repairBookKinds } from '../repair.js'

vi.mock('electron', () => ({
  app: {
    on: vi.fn(),
    getPath: vi.fn().mockReturnValue('/tmp/test')
  },
  ipcMain: { handle: vi.fn() }
}))

function makeDb(): Database.Database {
  const sqlite = new Database(':memory:')
  const ddl = `
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL,
      filepath TEXT NOT NULL
    );
  `
  sqlite.prepare(ddl).run()
  return sqlite
}

function insert(db: Database.Database, kind: string, filepath: string): void {
  db.prepare('INSERT INTO books (kind, filepath) VALUES (?, ?)').run(kind, filepath)
}

describe('repairBookKinds', () => {
  let db: Database.Database
  beforeEach(() => {
    db = makeDb()
  })

  it("flips kind='mobi' to 'azw3' for rows whose filepath ends in .azw3", () => {
    insert(db, 'mobi', '/data/legacy.azw3')
    insert(db, 'mobi', '/data/real.mobi')
    insert(db, 'epub', '/data/book.epub')
    insert(db, 'azw3', '/data/already-fixed.azw3')
    insert(db, 'mobi', '/data/MIXED-CASE.AZW3')

    const changed = repairBookKinds(db)
    expect(changed).toBe(2)

    const rows = db.prepare('SELECT kind, filepath FROM books ORDER BY id').all()
    expect(rows).toEqual([
      { kind: 'azw3', filepath: '/data/legacy.azw3' },
      { kind: 'mobi', filepath: '/data/real.mobi' },
      { kind: 'epub', filepath: '/data/book.epub' },
      { kind: 'azw3', filepath: '/data/already-fixed.azw3' },
      { kind: 'azw3', filepath: '/data/MIXED-CASE.AZW3' }
    ])
  })

  it('is idempotent — second run changes nothing', () => {
    insert(db, 'mobi', '/x/y.azw3')
    expect(repairBookKinds(db)).toBe(1)
    expect(repairBookKinds(db)).toBe(0)
  })

  it('does not touch rows where filepath does not end in .azw3', () => {
    insert(db, 'mobi', '/data/foo.azw3.bak')
    insert(db, 'mobi', '/data/x.azw3.tmp')
    insert(db, 'mobi', '/data/azw3-folder/book.mobi')

    expect(repairBookKinds(db)).toBe(0)
    const rows = db.prepare('SELECT kind FROM books').all() as { kind: string }[]
    expect(rows.every((r) => r.kind === 'mobi')).toBe(true)
  })
})
