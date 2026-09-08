CREATE TABLE IF NOT EXISTS ai_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    preferences_json TEXT NOT NULL,
    modified_at INTEGER NOT NULL CHECK (modified_at >= 0),
    mutation_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_devices (
    device_id TEXT PRIMARY KEY,
    platform TEXT NOT NULL CHECK (platform IN ('macOS', 'iOS')),
    has_api_key INTEGER CHECK (has_api_key IS NULL OR has_api_key IN (0, 1))
);
