CREATE TABLE IF NOT EXISTS recording_folders (
  id TEXT PRIMARY KEY NOT NULL,
  metadata_json TEXT NOT NULL CHECK (length(metadata_json) <= 65536),
  modified_at INTEGER NOT NULL CHECK (modified_at >= 0),
  mutation_id TEXT NOT NULL,
  deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_recording_folders_order ON recording_folders (id);
CREATE INDEX IF NOT EXISTS idx_recording_folders_modified ON recording_folders (modified_at, mutation_id);
