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
