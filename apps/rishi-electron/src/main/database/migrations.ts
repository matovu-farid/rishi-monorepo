import type Database from 'better-sqlite3'

/**
 * Initialize the database schema.
 * Uses user_version pragma to track whether the schema has been created.
 * If the database already exists from a previous version, it is dropped and recreated.
 */
const CURRENT_VERSION = 6

export function runMigrations(db: Database.Database): number {
  const version = db.pragma('user_version', { simple: true }) as number

  if (version >= CURRENT_VERSION) {
    return 0 // Already up to date
  }

  if (version < 1) {
    // Drop all existing tables (fresh start)
    const tables = db
      .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
      .all() as Array<{ name: string }>

    for (const { name } of tables) {
      db.exec(`DROP TABLE IF EXISTS "${name}"`)
    }

    // Create all tables from scratch
    db.exec(`
      -- books
      CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        cover BLOB NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        publisher TEXT NOT NULL DEFAULT '',
        filepath TEXT NOT NULL,
        location TEXT NOT NULL DEFAULT '',
        cover_kind TEXT NOT NULL DEFAULT 'png',
        version INTEGER NOT NULL DEFAULT 0,
        sync_id TEXT,
        file_hash TEXT,
        file_r2_key TEXT,
        cover_r2_key TEXT,
        file_size INTEGER NOT NULL DEFAULT 0,
        format TEXT NOT NULL DEFAULT 'epub',
        current_cfi TEXT,
        current_page INTEGER,
        user_id TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        is_dirty INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0
      );

      -- chunk_data
      CREATE TABLE IF NOT EXISTS chunk_data (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        page_number INTEGER NOT NULL,
        book_id INTEGER NOT NULL,
        data TEXT NOT NULL,
        FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
      );

      -- FTS5 virtual table
      CREATE VIRTUAL TABLE IF NOT EXISTS chunk_data_fts USING fts5(
        data,
        content='chunk_data',
        content_rowid='id'
      );

      -- Triggers to keep FTS index in sync with chunk_data
      CREATE TRIGGER IF NOT EXISTS chunk_data_ai AFTER INSERT ON chunk_data BEGIN
        INSERT INTO chunk_data_fts(rowid, data) VALUES (new.id, new.data);
      END;

      CREATE TRIGGER IF NOT EXISTS chunk_data_ad AFTER DELETE ON chunk_data BEGIN
        INSERT INTO chunk_data_fts(chunk_data_fts, rowid, data) VALUES('delete', old.id, old.data);
      END;

      CREATE TRIGGER IF NOT EXISTS chunk_data_au AFTER UPDATE ON chunk_data BEGIN
        INSERT INTO chunk_data_fts(chunk_data_fts, rowid, data) VALUES('delete', old.id, old.data);
        INSERT INTO chunk_data_fts(rowid, data) VALUES (new.id, new.data);
      END;

      -- highlights (book_id is TEXT - stores sync_id UUID, not integer FK)
      CREATE TABLE IF NOT EXISTS highlights (
        id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        cfi_range TEXT NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        color TEXT NOT NULL DEFAULT 'yellow',
        note TEXT NOT NULL DEFAULT '',
        chapter TEXT,
        created_at TEXT NOT NULL DEFAULT '',
        updated_at INTEGER,
        sync_id TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        is_dirty INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0
      );

      -- bookmarks (book_id is TEXT - stores sync_id UUID)
      CREATE TABLE IF NOT EXISTS bookmarks (
        id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        location TEXT NOT NULL,
        label TEXT NOT NULL DEFAULT '',
        page_number INTEGER,
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        sync_version INTEGER NOT NULL DEFAULT 0,
        is_dirty INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0
      );

      -- conversations (book_id is TEXT - stores sync_id UUID)
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        user_id TEXT,
        created_at TEXT NOT NULL DEFAULT '',
        updated_at INTEGER,
        sync_id TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        is_dirty INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0
      );

      -- messages
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        source_chunks TEXT,
        created_at TEXT NOT NULL DEFAULT '',
        updated_at INTEGER,
        sync_id TEXT,
        sync_version INTEGER NOT NULL DEFAULT 0,
        is_dirty INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0
      );

      -- sync_meta
      CREATE TABLE IF NOT EXISTS sync_meta (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        last_sync_version INTEGER NOT NULL DEFAULT 0,
        last_sync_at TEXT
      );
    `)

    db.pragma('user_version = 1')
  }

  if (version < 2) {
    // v2: Add format and locator columns to highlights for PDF support.
    // Note: cfi_range retains its NOT NULL constraint on-disk; PDF rows
    // write '' and the row mapper translates '' -> null on read.
    db.exec(`ALTER TABLE highlights ADD COLUMN format TEXT NOT NULL DEFAULT 'epub'`)
    db.exec(`ALTER TABLE highlights ADD COLUMN locator TEXT`)

    db.pragma('user_version = 2')
  }

  if (version < 3) {
    db.exec(`ALTER TABLE books ADD COLUMN last_paragraph TEXT`)
    db.pragma('user_version = 3')
  }

  if (version < 4) {
    // v4: track on-disk file size per book so it can ride the sync push up
    // to the cloud. The worker enforces per-user storage + per-file caps on
    // /upload-url; the cloud books.file_size column mirrors this one.
    //
    // Fresh DBs created from v1 already include this column (the v1 CREATE
    // TABLE was retro-added at commit 60c2501d). Only ALTER when the column
    // is missing — that's the legacy-DB path where v1 ran before the column
    // landed in the table definition.
    const cols = db.prepare('PRAGMA table_info(books)').all() as Array<{ name: string }>
    if (!cols.some((c) => c.name === 'file_size')) {
      db.exec('ALTER TABLE books ADD COLUMN file_size INTEGER NOT NULL DEFAULT 0')
    }
    db.pragma('user_version = 4')
  }

  if (version < 5) {
    // v5 (#142): reserved version slot. An earlier draft wiped
    // chunk_data so footer-aware re-extraction could happen — but
    // that paralyzed library-level TTS prefetch (ttsPrefetch.ts gates
    // on hasSavedEpubData, which queries chunk_data). Existing chunks
    // keep their pre-heuristic content; only pages not yet in
    // chunk_data get extracted with the footer mask applied.
    db.pragma('user_version = 5')
  }

  if (version < 6) {
    // v6 (Plan 2 Task 22): sharing-provenance columns on `books`. P2P-received
    // books mark `source='shared-session'` and carry the sharer's userId +
    // ms timestamp; local-only books leave all three NULL.
    db.exec(`ALTER TABLE books ADD COLUMN source TEXT`)
    db.exec(`ALTER TABLE books ADD COLUMN received_from_user_id TEXT`)
    db.exec(`ALTER TABLE books ADD COLUMN received_at INTEGER`)
    db.pragma('user_version = 6')
  }

  return 1
}
