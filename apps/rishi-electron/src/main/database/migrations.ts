import type Database from "better-sqlite3";

/**
 * Each migration has a version number and a function that applies the migration.
 * Migrations are applied in order, and the current version is tracked in a
 * dedicated `schema_version` pragma so we never re-run a migration.
 */
interface Migration {
  version: number;
  description: string;
  up: (db: Database.Database) => void;
}

const migrations: Migration[] = [
  {
    version: 1,
    description: "Create initial schema — books, chunks, FTS, highlights, bookmarks, conversations, messages, sync_meta",
    up(db) {
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

        -- highlights
        CREATE TABLE IF NOT EXISTS highlights (
          id TEXT PRIMARY KEY,
          book_id INTEGER NOT NULL,
          cfi_range TEXT NOT NULL,
          text TEXT NOT NULL DEFAULT '',
          color TEXT NOT NULL DEFAULT 'yellow',
          note TEXT NOT NULL DEFAULT '',
          chapter TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at INTEGER,
          sync_id TEXT,
          sync_version INTEGER NOT NULL DEFAULT 0,
          is_dirty INTEGER NOT NULL DEFAULT 1,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        );

        -- bookmarks
        CREATE TABLE IF NOT EXISTS bookmarks (
          id TEXT PRIMARY KEY,
          book_id INTEGER NOT NULL,
          location TEXT NOT NULL,
          label TEXT NOT NULL DEFAULT '',
          page_number INTEGER,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at INTEGER,
          sync_version INTEGER NOT NULL DEFAULT 0,
          is_dirty INTEGER NOT NULL DEFAULT 1,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        );

        -- conversations
        CREATE TABLE IF NOT EXISTS conversations (
          id TEXT PRIMARY KEY,
          book_id INTEGER NOT NULL,
          title TEXT NOT NULL DEFAULT '',
          user_id TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at INTEGER,
          sync_id TEXT,
          sync_version INTEGER NOT NULL DEFAULT 0,
          is_dirty INTEGER NOT NULL DEFAULT 1,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
        );

        -- messages
        CREATE TABLE IF NOT EXISTS messages (
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          source_chunks TEXT,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at INTEGER,
          sync_id TEXT,
          sync_version INTEGER NOT NULL DEFAULT 0,
          is_dirty INTEGER NOT NULL DEFAULT 1,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        );

        -- sync_meta
        CREATE TABLE IF NOT EXISTS sync_meta (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          last_sync_version INTEGER NOT NULL DEFAULT 0,
          last_sync_at TEXT
        );
      `);
    },
  },
];

/**
 * Returns the current schema version stored in the database's user_version pragma.
 */
function getSchemaVersion(db: Database.Database): number {
  const row = db.pragma("user_version", { simple: true });
  return typeof row === "number" ? row : 0;
}

/**
 * Sets the schema version in the database's user_version pragma.
 */
function setSchemaVersion(db: Database.Database, version: number): void {
  db.pragma(`user_version = ${version}`);
}

/**
 * Run all pending migrations inside a transaction per migration.
 * Returns the number of migrations that were applied.
 */
export function runMigrations(db: Database.Database): number {
  const currentVersion = getSchemaVersion(db);
  const pending = migrations.filter((m) => m.version > currentVersion);

  if (pending.length === 0) {
    return 0;
  }

  // Sort ascending to guarantee order
  pending.sort((a, b) => a.version - b.version);

  for (const migration of pending) {
    const runMigration = db.transaction(() => {
      migration.up(db);
      setSchemaVersion(db, migration.version);
    });

    runMigration();
  }

  return pending.length;
}
