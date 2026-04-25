-- Drop triggers first
DROP TRIGGER IF EXISTS chunk_data_ai;
DROP TRIGGER IF EXISTS chunk_data_ad;
DROP TRIGGER IF EXISTS chunk_data_au;

-- Drop FTS virtual table
DROP TABLE IF EXISTS chunk_data_fts;

-- Drop tables in reverse order
DROP TABLE IF EXISTS sync_meta;
DROP TABLE IF EXISTS bookmarks;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS conversations;
DROP TABLE IF EXISTS highlights;
DROP TABLE IF EXISTS chunk_data;
DROP TABLE IF EXISTS books;
