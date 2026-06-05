/**
 * Shared better-sqlite3 adapter for PDF tests that need a real SQLite engine.
 *
 * Import this module BEFORE any @/lib/db import. The jest.mock() call that
 * uses this factory must live at the TOP of the test file (Jest hoists it
 * before imports), but the factory implementation can live here so it isn't
 * duplicated across test files.
 *
 * Usage in a test file:
 *
 *   import { makeSqliteAdapter } from './__tests__/pdf/test-db'
 *   jest.mock('expo-sqlite', () => ({ openDatabaseSync: () => makeSqliteAdapter() }))
 *   import { rawDb, runMigrations, migrations } from '@/lib/db'
 */

import Database from 'better-sqlite3'

export function makeSqliteAdapter() {
  const db = new Database(':memory:')
  return {
    execSync(sql: string) {
      db.exec(sql)
    },
    getAllSync<T>(sql: string): T[] {
      return db.prepare(sql).all() as T[]
    },
    getFirstSync<T>(sql: string): T | undefined {
      return db.prepare(sql).get() as T | undefined
    },
  }
}
