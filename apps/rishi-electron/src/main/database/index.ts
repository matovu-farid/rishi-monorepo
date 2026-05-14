import { app } from 'electron'
import { join } from 'path'
import BetterSqlite3 from 'better-sqlite3'
import type Database from 'better-sqlite3'
import { runMigrations } from './migrations.js'
import { repairBookKinds } from './repair.js'

let db: Database.Database | null = null

/**
 * Returns the singleton database instance.
 * Throws if called before `initDatabase()`.
 */
export function getDb(): Database.Database {
  if (!db) {
    throw new Error('Database not initialized. Call initDatabase() before accessing the database.')
  }
  return db
}

/**
 * Initialise the SQLite database:
 *  1. Open (or create) `rishi.db` in the user-data directory.
 *  2. Enable WAL journal mode for concurrent read/write access.
 *  3. Enable foreign key enforcement.
 *  4. Run any pending schema migrations.
 *
 * This function is idempotent — calling it more than once is a no-op.
 */
export function initDatabase(): void {
  if (db) {
    return
  }

  const dbPath = join(app.getPath('userData'), 'rishi.db')

  db = new BetterSqlite3(dbPath)

  // Performance & safety pragmas
  db.pragma('journal_mode = WAL')
  db.pragma('foreign_keys = ON')
  db.pragma('busy_timeout = 5000')

  const applied = runMigrations(db)
  if (applied > 0) {
    console.log(`[database] Applied ${applied} migration(s)`)
  }

  const repaired = repairBookKinds(db)
  if (repaired > 0) {
    console.log(`[database] Repaired ${repaired} AZW3 books mis-tagged as MOBI`)
  }

  console.log(`[database] Ready — ${dbPath}`)
}

/**
 * Gracefully close the database connection.
 * Safe to call multiple times.
 */
export function closeDatabase(): void {
  if (db) {
    db.close()
    db = null
  }
}

// Ensure the database is closed when the app quits
app.on('will-quit', () => {
  closeDatabase()
})
