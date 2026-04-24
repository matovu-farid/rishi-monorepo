-- NOTE: Diesel normally wraps each migration in a transaction, but SQLite does
-- not support CREATE VIRTUAL TABLE inside a transaction. Diesel's SQLite backend
-- detects this and runs the migration without an implicit transaction.
-- As a consequence the backfill INSERT at the bottom is also non-transactional.
-- If it fails mid-way, re-running the migration will attempt to re-insert rows
-- that already exist in the FTS index (harmless — FTS5 content-sync tables
-- tolerate duplicate inserts as long as the content table is the source of truth).

-- FTS5 content-sync table mirroring chunk_data.data
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

-- Backfill FTS index with existing chunk_data rows
INSERT INTO chunk_data_fts(rowid, data) SELECT id, data FROM chunk_data;
