-- Books table
CREATE TABLE books (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    cover BLOB NOT NULL,
    title TEXT NOT NULL,
    author TEXT NOT NULL,
    publisher TEXT NOT NULL,
    filepath TEXT NOT NULL,
    location TEXT NOT NULL,
    cover_kind TEXT NOT NULL,
    version INTEGER NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
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

-- Chunk data table
CREATE TABLE chunk_data (
    id BIGINT NOT NULL PRIMARY KEY,
    pageNumber INTEGER NOT NULL,
    bookId INTEGER NOT NULL,
    data TEXT NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- FTS5 virtual table for full-text search on chunk_data
CREATE VIRTUAL TABLE chunk_data_fts USING fts5(
    data,
    content='chunk_data',
    content_rowid='id'
);

-- Keep FTS index in sync with chunk_data
CREATE TRIGGER chunk_data_ai AFTER INSERT ON chunk_data BEGIN
    INSERT INTO chunk_data_fts(rowid, data) VALUES (new.id, new.data);
END;

CREATE TRIGGER chunk_data_ad AFTER DELETE ON chunk_data BEGIN
    INSERT INTO chunk_data_fts(chunk_data_fts, rowid, data) VALUES('delete', old.id, old.data);
END;

CREATE TRIGGER chunk_data_au AFTER UPDATE ON chunk_data BEGIN
    INSERT INTO chunk_data_fts(chunk_data_fts, rowid, data) VALUES('delete', old.id, old.data);
    INSERT INTO chunk_data_fts(rowid, data) VALUES (new.id, new.data);
END;

-- Highlights table
CREATE TABLE highlights (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    cfi_range TEXT NOT NULL,
    text TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'yellow',
    note TEXT,
    chapter TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);

-- Conversations table
CREATE TABLE conversations (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    title TEXT NOT NULL DEFAULT 'New conversation',
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);

-- Messages table
CREATE TABLE messages (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    source_chunks TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);

-- Bookmarks table
CREATE TABLE bookmarks (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    user_id TEXT,
    location TEXT NOT NULL,
    label TEXT,
    created_at INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0,
    sync_version INTEGER NOT NULL DEFAULT 0,
    is_dirty INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0
);

-- Sync metadata table
CREATE TABLE sync_meta (
    id TEXT PRIMARY KEY NOT NULL,
    last_sync_version INTEGER NOT NULL DEFAULT 0,
    last_sync_at INTEGER
);

-- Seed default sync_meta row
INSERT INTO sync_meta (id, last_sync_version) VALUES ('default', 0);
