import { drizzle } from 'drizzle-orm/expo-sqlite'
import { openDatabaseSync } from 'expo-sqlite'
import * as schema from '@rishi/shared/schema'

const expo = openDatabaseSync('rishi.db')
export const rawDb = expo

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

// Migration: add columns introduced in earlier phases. Gate on PRAGMA
// rather than try/catch — expo-sqlite logs every thrown ALTER as a scary
// 🟠 FunctionCallException at the native layer even when JS swallows it.
const existingBookCols = new Set(
  expo
    .getAllSync<{ name: string }>('PRAGMA table_info(books)')
    .map((r) => r.name)
)

const columnsToAdd: [string, string][] = [
  ['current_page', 'INTEGER'],
  ['file_hash', 'TEXT'],
  ['file_r2_key', 'TEXT'],
  ['cover_r2_key', 'TEXT'],
  ['user_id', 'TEXT'],
  ['updated_at', 'INTEGER NOT NULL DEFAULT 0'],
  ['sync_version', 'INTEGER DEFAULT 0'],
  ['is_dirty', 'INTEGER DEFAULT 1'],
  ['is_deleted', 'INTEGER DEFAULT 0'],
  ['file_size', 'INTEGER DEFAULT 0'],
  // DAT-003: mobile-only recovery flag. Flipped to 1 when the post-fetch
  // atomic `tmpFile.move()` fails in `downloadBookFile`. UI uses it (via
  // the download-error-store) to surface a retry affordance.
  ['file_needs_redownload', 'INTEGER DEFAULT 0'],
  // #41 — Persisted 0..1 progress float for the library "Reading Now"
  // pill subline. Nullable: legacy rows that pre-date the migration
  // (and rows that have never been opened in a reader) stay null and
  // the pill omits the subline rather than showing a stale "0%".
  ['last_progress_percent', 'REAL'],
]

for (const [col, type] of columnsToAdd) {
  if (existingBookCols.has(col)) continue
  const sql = 'ALTER TABLE books ADD COLUMN ' + col + ' ' + type
  expo.execSync(sql)
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

// ─── Bookmarks table ──────────────────────────────────────────────────────────
expo.execSync(`
  CREATE TABLE IF NOT EXISTS bookmarks (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    location TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    page_number INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
  );
`)

// ─── Conversations table ──────────────────────────────────────────────────────
expo.execSync(`
  CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    title TEXT NOT NULL DEFAULT 'New conversation',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
  );
`)

// ─── Messages table ──────────────────────────────────────────────────────────
expo.execSync(`
  CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    source_chunks TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    sync_version INTEGER DEFAULT 0,
    is_dirty INTEGER DEFAULT 1,
    is_deleted INTEGER DEFAULT 0
  );
`)

// ─── Sync-in-progress marker ─────────────────────────────────────────────────
expo.execSync(`
  CREATE TABLE IF NOT EXISTS sync_state (
    id TEXT PRIMARY KEY NOT NULL,
    in_progress INTEGER NOT NULL DEFAULT 0
  );
`)
expo.execSync("INSERT OR IGNORE INTO sync_state (id, in_progress) VALUES ('default', 0)")

// ─── Drizzle instance ─────────────────────────────────────────────────────────
export const db = drizzle(expo, { schema })
export type AppDb = typeof db

// ─── Sync marker helpers ─────────────────────────────────────────────────────
export function markSyncInProgress(inProgress: boolean): void {
  expo.execSync(
    `UPDATE sync_state SET in_progress = ${inProgress ? 1 : 0} WHERE id = 'default'`
  )
}

export function wasSyncInterrupted(): boolean {
  const row = expo.getFirstSync<{ in_progress: number }>(
    "SELECT in_progress FROM sync_state WHERE id = 'default'"
  )
  return row?.in_progress === 1
}
