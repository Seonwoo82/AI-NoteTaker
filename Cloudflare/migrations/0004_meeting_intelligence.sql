CREATE TABLE IF NOT EXISTS text_profile (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    profile_json TEXT NOT NULL CHECK (length(profile_json) <= 65536),
    modified_at INTEGER NOT NULL CHECK (modified_at >= 0),
    mutation_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS meeting_intelligence (
    recording_id TEXT NOT NULL,
    audio_version INTEGER NOT NULL CHECK (audio_version >= 1),
    generated_at_millis INTEGER NOT NULL CHECK (generated_at_millis >= 0),
    mutation_id TEXT NOT NULL,
    revision TEXT NOT NULL CHECK (length(revision) = 64),
    byte_count INTEGER NOT NULL CHECK (byte_count >= 1 AND byte_count <= 4194304),
    object_key TEXT NOT NULL,
    sync_key TEXT NOT NULL,
    PRIMARY KEY (recording_id, audio_version),
    FOREIGN KEY (recording_id) REFERENCES recordings(id)
);

CREATE INDEX IF NOT EXISTS idx_meeting_intelligence_order ON meeting_intelligence (sync_key);
CREATE INDEX IF NOT EXISTS idx_meeting_intelligence_lww ON meeting_intelligence (generated_at_millis, mutation_id);

CREATE TABLE IF NOT EXISTS meeting_edits (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    recording_id TEXT NOT NULL,
    audio_version INTEGER NOT NULL CHECK (audio_version >= 1),
    payload_json TEXT NOT NULL CHECK (length(payload_json) <= 16384),
    FOREIGN KEY (recording_id) REFERENCES recordings(id)
);

CREATE INDEX IF NOT EXISTS idx_meeting_edits_order ON meeting_edits (sequence);
CREATE INDEX IF NOT EXISTS idx_meeting_edits_recording ON meeting_edits (recording_id, audio_version);
