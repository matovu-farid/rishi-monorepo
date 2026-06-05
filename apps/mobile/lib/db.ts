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

// ─── Schema-migration runner ─────────────────────────────────────────────────
//
// DAT-014 (#126): the bootstrap above is a fixed sequence of CREATE TABLE
// IF NOT EXISTS + ALTER TABLE statements that always runs every module
// load. There was no PRAGMA user_version check, so a future "drop column",
// "rename table", or "rewrite key shape" couldn't run conditionally.
// Authors would have to hand-edit the bootstrap and there'd be no record
// of which devices had already executed which migration.
//
// runMigrations(db, target, migrations) is the minimal forward-only
// runner that future schema bumps should use:
//   1. Read PRAGMA user_version. If it equals target, no-op.
//   2. If it is GREATER than target, refuse — downgrades are unsafe.
//   3. Run every migration whose version is greater than the stored
//      user_version, in ascending order. Errors propagate (better to
//      crash than persist a half-migrated DB; next launch re-runs from
//      the failed step because user_version was NOT bumped).
//   4. After all migrations succeed, write
//      `PRAGMA user_version = <target>`.
//
// Migration policy:
//   - Migrations are forward-only. To revert, ship a NEW migration that
//     undoes the change with a higher version number.
//   - The current bootstrap above is the implicit "v0" state. New
//     schema work should add a Migration{ version: 1, run } entry and
//     call runMigrations(rawDb, 1, [...]) at the end of this file.
//   - The runner deliberately does NOT wrap migrations in a single
//     transaction — expo-sqlite's ALTER TABLE statements are auto-
//     committed individually, and we want partial progress to survive a
//     crash so the next launch picks up where we stopped.
export interface Migration {
  /** Strictly positive monotonic version number. */
  version: number
  /** Idempotent migration body. Receives the raw expo-sqlite database. */
  run: (db: MigrationDb) => void
}

interface MigrationDb {
  // eslint-disable-next-line @typescript-eslint/method-signature-style
  execSync(sql: string): void
  // eslint-disable-next-line @typescript-eslint/method-signature-style
  getFirstSync<T = unknown>(sql: string): T | undefined
}

export function runMigrations(
  database: MigrationDb,
  targetVersion: number,
  migrations: Migration[],
): void {
  const row = database.getFirstSync<{ user_version: number }>('PRAGMA user_version')
  const storedVersion = row?.user_version ?? 0

  if (storedVersion === targetVersion) return
  if (storedVersion > targetVersion) {
    throw new Error(
      `[db] refusing to downgrade schema: stored user_version=${storedVersion} > target=${targetVersion}`,
    )
  }

  // Sort ascending by version so we always migrate older->newer regardless
  // of caller-provided order.
  const sorted = [...migrations].sort((a, b) => a.version - b.version)

  // Sanity: the highest migration version must match the target so callers
  // can't silently skip a step.
  const highest = sorted.length > 0 ? sorted[sorted.length - 1].version : 0
  if (highest !== targetVersion) {
    throw new Error(
      `[db] missing migration: target=${targetVersion} but highest provided version=${highest}`,
    )
  }

  for (const m of sorted) {
    if (m.version <= storedVersion) continue
    m.run(database) // run() may throw; intentionally propagate.
  }

  database.execSync(`PRAGMA user_version = ${targetVersion}`)
}

// ─── Monotonic local timestamp ───────────────────────────────────────────────
//
// DAT-015 (#127): the sync engine's conflict resolution compares
// `updatedAt` integers — equal stamps fall through and the remote write
// wins, silently overwriting the local edit. Two writes generated in the
// same JS millisecond (a RAG answer + auto-title, two debounced reading-
// progress saves, etc.) are the most common failure mode.
//
// `nextLocalTimestamp()` returns a strictly-monotonic integer. It is
// initialized to `Date.now()` and clamped to `max(Date.now(), last + 1)`
// on every call so consecutive writes are always orderable on the same
// device. Across devices this does NOT provide a tiebreaker (each device
// has its own counter) — that requires a server-side revision id in a
// future migration; this fix removes the within-device portion of the
// failure mode without a schema bump.
let lastLocalTimestamp = 0
export function nextLocalTimestamp(): number {
  const now = Date.now()
  lastLocalTimestamp = now > lastLocalTimestamp ? now : lastLocalTimestamp + 1
  return lastLocalTimestamp
}

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

// ─── Path E migrations ────────────────────────────────────────────────────────
//
// v1: add the PDF text-extraction cache tables (book_pages, book_words,
// book_paragraphs) and the four extraction-status columns on `books`. Pure
// additive — no destructive changes — so the migration is safe to re-run on
// devices that already saw an earlier release.
export const migrations: Migration[] = [
  {
    version: 1,
    run(database) {
      // Status columns on `books`. Each ALTER is gated on PRAGMA so a re-run
      // doesn't throw (this mirrors the bootstrap pattern above).
      const existing = new Set(
        (database as unknown as {
          getAllSync<T>(sql: string): T[]
        })
          .getAllSync<{ name: string }>('PRAGMA table_info(books)')
          .map((r) => r.name),
      )
      const newBookCols: [string, string][] = [
        ['extraction_status', 'TEXT'],
        ['extracted_pages', 'INTEGER DEFAULT 0'],
        ['total_pages', 'INTEGER'],
        ['extraction_error', 'TEXT'],
      ]
      for (const [col, type] of newBookCols) {
        if (existing.has(col)) continue
        database.execSync(`ALTER TABLE books ADD COLUMN ${col} ${type}`)
      }

      database.execSync(`
        CREATE TABLE IF NOT EXISTS book_pages (
          book_id     TEXT    NOT NULL,
          page_number INTEGER NOT NULL,
          text        TEXT    NOT NULL DEFAULT '',
          width_pts   REAL    NOT NULL,
          height_pts  REAL    NOT NULL,
          indexed_at  INTEGER NOT NULL,
          PRIMARY KEY (book_id, page_number)
        )
      `)
      database.execSync(
        `CREATE INDEX IF NOT EXISTS idx_book_pages_book ON book_pages(book_id)`,
      )

      database.execSync(`
        CREATE TABLE IF NOT EXISTS book_words (
          book_id     TEXT    NOT NULL,
          page_number INTEGER NOT NULL,
          idx         INTEGER NOT NULL,
          text        TEXT    NOT NULL,
          x           REAL    NOT NULL,
          y           REAL    NOT NULL,
          w           REAL    NOT NULL,
          h           REAL    NOT NULL,
          PRIMARY KEY (book_id, page_number, idx)
        )
      `)
      database.execSync(
        `CREATE INDEX IF NOT EXISTS idx_book_words_book_page ON book_words(book_id, page_number)`,
      )

      database.execSync(`
        CREATE TABLE IF NOT EXISTS book_paragraphs (
          book_id         TEXT NOT NULL,
          page_number     INTEGER NOT NULL,
          paragraph_index TEXT NOT NULL,
          text            TEXT NOT NULL,
          PRIMARY KEY (book_id, paragraph_index)
        )
      `)
      database.execSync(
        `CREATE INDEX IF NOT EXISTS idx_book_paragraphs_book ON book_paragraphs(book_id)`,
      )
    },
  },
]

runMigrations(rawDb, 1, migrations)
