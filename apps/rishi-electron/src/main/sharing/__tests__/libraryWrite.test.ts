import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import BetterSqlite3 from 'better-sqlite3'
import type { Database } from 'better-sqlite3'

// libraryWrite.ts pulls in `electron` (via ../database/index.js → app.on(...))
// at module top-level. Stub the surface so the import chain doesn't crash
// under plain Node / vitest.
vi.mock('electron', () => ({
  app: {
    on: () => {},
    getPath: (key: string): string => {
      if (key !== 'userData') throw new Error(`unexpected getPath(${key})`)
      return os.tmpdir()
    }
  }
}))

import { _discardTransferredBookWithDb, SHARED_SESSION_SOURCE } from '../libraryWrite.js'
import { runMigrations } from '../../database/migrations.js'

function makeDb(): Database {
  const db = new BetterSqlite3(':memory:')
  runMigrations(db)
  return db
}

function insertBook(
  db: Database,
  row: { title: string; filepath: string; source: string | null }
): number {
  const info = db
    .prepare(
      `INSERT INTO books (kind, cover, title, filepath, format, source)
       VALUES ('epub', x'00', @title, @filepath, 'epub', @source)`
    )
    .run(row)
  return Number(info.lastInsertRowid)
}

describe('_discardTransferredBookWithDb', () => {
  let db: Database
  let tmpDir = ''

  beforeEach(async () => {
    db = makeDb()
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'rishi-discard-'))
  })

  afterEach(async () => {
    db.close()
    await fs.rm(tmpDir, { recursive: true, force: true })
  })

  it('deletes a row whose source is the shared-session sentinel', async () => {
    const sharedFile = path.join(tmpDir, 'shared.epub')
    await fs.writeFile(sharedFile, 'shared')
    const sharedId = insertBook(db, {
      title: 'Shared',
      filepath: sharedFile,
      source: SHARED_SESSION_SOURCE
    })

    await _discardTransferredBookWithDb(db, {
      dbBookId: sharedId,
      localPath: sharedFile
    })

    const row = db.prepare('SELECT id FROM books WHERE id = ?').get(sharedId)
    expect(row).toBeUndefined()
  })

  it('does NOT delete a row whose source is not the shared-session sentinel', async () => {
    const userFile = path.join(tmpDir, 'user-import.epub')
    await fs.writeFile(userFile, 'user import bytes')
    const userId = insertBook(db, {
      title: 'User Import',
      filepath: userFile,
      source: 'user-import'
    })

    await _discardTransferredBookWithDb(db, {
      dbBookId: userId,
      localPath: '/tmp/does-not-exist-and-thats-fine'
    })

    const row = db.prepare('SELECT id, title FROM books WHERE id = ?').get(userId) as
      | { id: number; title: string }
      | undefined
    expect(row).toBeDefined()
    expect(row?.title).toBe('User Import')
  })

  it('does NOT delete a row whose source is NULL (locally-added book)', async () => {
    const localFile = path.join(tmpDir, 'local.epub')
    await fs.writeFile(localFile, 'local bytes')
    const localId = insertBook(db, {
      title: 'Local',
      filepath: localFile,
      source: null
    })

    await _discardTransferredBookWithDb(db, {
      dbBookId: localId,
      localPath: localFile
    })

    const row = db.prepare('SELECT id FROM books WHERE id = ?').get(localId)
    expect(row).toBeDefined()
  })

  it('only deletes the targeted shared-session row, leaving siblings intact', async () => {
    const a = path.join(tmpDir, 'a.epub')
    const b = path.join(tmpDir, 'b.epub')
    await fs.writeFile(a, 'a')
    await fs.writeFile(b, 'b')
    const sharedId = insertBook(db, {
      title: 'Shared A',
      filepath: a,
      source: SHARED_SESSION_SOURCE
    })
    const importId = insertBook(db, {
      title: 'Import B',
      filepath: b,
      source: 'user-import'
    })

    await _discardTransferredBookWithDb(db, {
      dbBookId: sharedId,
      localPath: a
    })

    expect(db.prepare('SELECT id FROM books WHERE id = ?').get(sharedId)).toBeUndefined()
    expect(db.prepare('SELECT id FROM books WHERE id = ?').get(importId)).toBeDefined()
  })

  it('still unlinks the on-disk file even when the DELETE is a no-op', async () => {
    // why: a stale shared-session file may legitimately outlive its DB row
    // (e.g. crash between INSERT-revert and unlink); the unlink must run
    // regardless of provenance so we do not leak bytes.
    const staleFile = path.join(tmpDir, 'stale.epub')
    await fs.writeFile(staleFile, 'stale bytes')

    // Insert a row with a *different* source so the DELETE matches nothing.
    insertBook(db, {
      title: 'Wrong Source',
      filepath: staleFile,
      source: 'user-import'
    })

    await _discardTransferredBookWithDb(db, {
      dbBookId: 999999, // non-existent id
      localPath: staleFile
    })

    await expect(fs.access(staleFile)).rejects.toThrow()
  })
})
