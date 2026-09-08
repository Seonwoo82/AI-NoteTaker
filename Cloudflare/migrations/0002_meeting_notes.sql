CREATE TABLE IF NOT EXISTS meeting_notes (
  recording_id TEXT NOT NULL,
  audio_version INTEGER NOT NULL CHECK (audio_version >= 1),
  generated_at_millis INTEGER NOT NULL CHECK (generated_at_millis >= 0),
  revision TEXT NOT NULL CHECK (length(revision) = 64),
  byte_count INTEGER NOT NULL CHECK (byte_count >= 1 AND byte_count <= 2097152),
  object_key TEXT NOT NULL,
  sync_key TEXT NOT NULL,
  PRIMARY KEY (recording_id, audio_version),
  FOREIGN KEY (recording_id) REFERENCES recordings(id)
);

CREATE INDEX IF NOT EXISTS idx_meeting_notes_order ON meeting_notes (sync_key);
CREATE INDEX IF NOT EXISTS idx_meeting_notes_lww ON meeting_notes (generated_at_millis, revision);
