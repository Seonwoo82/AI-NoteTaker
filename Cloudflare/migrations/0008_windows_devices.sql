-- Extend the device platform check while retaining existing Apple registrations and key-presence flags.
CREATE TABLE ai_devices_windows (
    device_id TEXT PRIMARY KEY,
    platform TEXT NOT NULL CHECK (platform IN ('macOS', 'iOS', 'Windows')),
    has_api_key INTEGER CHECK (has_api_key IS NULL OR has_api_key IN (0, 1))
);
INSERT INTO ai_devices_windows (device_id, platform, has_api_key)
SELECT device_id, platform, has_api_key FROM ai_devices;
DROP TABLE ai_devices;
ALTER TABLE ai_devices_windows RENAME TO ai_devices;
