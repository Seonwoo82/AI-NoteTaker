CREATE TABLE IF NOT EXISTS recordings (
  id TEXT PRIMARY KEY NOT NULL,
  metadata_json TEXT NOT NULL CHECK (length(metadata_json) <= 65536),
  modified_at INTEGER NOT NULL CHECK (modified_at >= 0),
  mutation_id TEXT NOT NULL,
  audio_version INTEGER NOT NULL CHECK (audio_version >= 1),
  deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_recordings_order ON recordings (id);
CREATE INDEX IF NOT EXISTS idx_recordings_modified ON recordings (modified_at, mutation_id);
