-- Add sync columns to existing books table
ALTER TABLE books ADD COLUMN sync_id TEXT;
ALTER TABLE books ADD COLUMN file_hash TEXT;
ALTER TABLE books ADD COLUMN file_r2_key TEXT;
ALTER TABLE books ADD COLUMN cover_r2_key TEXT;
ALTER TABLE books ADD COLUMN format TEXT NOT NULL DEFAULT 'epub';
ALTER TABLE books ADD COLUMN current_cfi TEXT;
ALTER TABLE books ADD COLUMN current_page INTEGER;
ALTER TABLE books ADD COLUMN user_id TEXT;
ALTER TABLE books ADD COLUMN sync_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE books ADD COLUMN is_dirty INTEGER NOT NULL DEFAULT 1;
ALTER TABLE books ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;

-- Back-fill sync_id with UUID v4 for existing books
UPDATE books SET sync_id = (
  lower(hex(randomblob(4))) || '-' ||
  lower(hex(randomblob(2))) || '-4' ||
  lower(substr(hex(randomblob(2)),2)) || '-' ||
  lower(substr('89ab', abs(random()) % 4 + 1, 1)) ||
  lower(substr(hex(randomblob(2)),2)) || '-' ||
  lower(hex(randomblob(6)))
) WHERE sync_id IS NULL;

-- Copy existing location to current_cfi for epub books
UPDATE books SET current_cfi = location WHERE kind = 'epub' AND location IS NOT NULL AND location != '';

-- Set format based on existing kind column
UPDATE books SET format = kind WHERE kind IN ('epub', 'pdf');

-- Create highlights table (matches mobile/D1 schema)
CREATE TABLE IF NOT EXISTS highlights (
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

-- Create conversations table
CREATE TABLE IF NOT EXISTS conversations (
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

-- Create messages table
CREATE TABLE IF NOT EXISTS messages (
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

-- Create sync_meta table
CREATE TABLE IF NOT EXISTS sync_meta (
    id TEXT PRIMARY KEY NOT NULL,
    last_sync_version INTEGER NOT NULL DEFAULT 0,
    last_sync_at INTEGER
);
INSERT OR IGNORE INTO sync_meta (id, last_sync_version) VALUES ('default', 0);
