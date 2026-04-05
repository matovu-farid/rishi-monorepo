import * as SQLite from 'expo-sqlite'

let db: SQLite.SQLiteDatabase | null = null

export function getDb(): SQLite.SQLiteDatabase {
  if (!db) {
    db = SQLite.openDatabaseSync('rishi.db')
    db.execSync(`
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

    // Migration: add current_page column for existing databases
    try {
      db.execSync('ALTER TABLE books ADD COLUMN current_page INTEGER')
    } catch {
      // Column already exists -- safe to ignore
    }
  }
  return db
}
