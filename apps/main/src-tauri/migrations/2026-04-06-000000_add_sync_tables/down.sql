DROP TABLE IF EXISTS sync_meta;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS conversations;
DROP TABLE IF EXISTS highlights;
-- SQLite cannot drop columns; these ALTER TABLEs are one-way
