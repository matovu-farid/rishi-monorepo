import { drizzle } from 'drizzle-orm/expo-sqlite'
import { openDatabaseSync } from 'expo-sqlite'
import * as schema from '@rishi/shared/schema'

const expo = openDatabaseSync('rishi.db')

// ─── Migrations ───────────────────────────────────────────────────────────────
// Ensure the base table exists (matches pre-Drizzle schema)
expo.execSync(`
  CREATE TABLE IF NOT EXISTS books (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL,
    author TEXT NOT NULL DEFAULT 'Unknown',
    cover_path TEXT,
    file_path TEXT NOT NULL,
    format TEXT NOT NULL DEFAULT 'epub',
    current_cfi TEXT,
    current_page INTEGER,
    created_at INTEGER NOT NULL
  );
`)

// Migration: add columns introduced in earlier phases
try { expo.execSync('ALTER TABLE books ADD COLUMN current_page INTEGER') } catch { /* already exists */ }

// Migration: add sync columns
const syncColumns: [string, string][] = [
  ['file_hash', 'TEXT'],
  ['file_r2_key', 'TEXT'],
  ['cover_r2_key', 'TEXT'],
  ['user_id', 'TEXT'],
  ['updated_at', 'INTEGER NOT NULL DEFAULT 0'],
  ['sync_version', 'INTEGER DEFAULT 0'],
  ['is_dirty', 'INTEGER DEFAULT 1'],
  ['is_deleted', 'INTEGER DEFAULT 0'],
]

for (const [col, type] of syncColumns) {
  try {
    expo.execSync(`ALTER TABLE books ADD COLUMN ${col} ${type}`)
  } catch {
    // Column already exists -- safe to ignore
  }
}

// Back-fill: set updated_at from created_at where it was defaulted to 0
expo.execSync('UPDATE books SET updated_at = created_at WHERE updated_at = 0')
// Back-fill: ensure all existing books are marked dirty for first sync
expo.execSync('UPDATE books SET is_dirty = 1 WHERE is_dirty = 0 OR is_dirty IS NULL')

// Create sync_meta table
expo.execSync(`
  CREATE TABLE IF NOT EXISTS sync_meta (
    id TEXT PRIMARY KEY NOT NULL,
    last_sync_version INTEGER DEFAULT 0,
    last_sync_at INTEGER
  );
`)
expo.execSync("INSERT OR IGNORE INTO sync_meta (id, last_sync_version) VALUES ('default', 0)")

// ─── Highlights table ──────────────────────────────────────────────────────────
expo.execSync(`
  CREATE TABLE IF NOT EXISTS highlights (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    cfi_range TEXT NOT NULL,
    text TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'yellow',
    note TEXT,
    chapter TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
  );
`)

// ─── Drizzle instance ─────────────────────────────────────────────────────────
export const db = drizzle(expo, { schema })
export type AppDb = typeof db
