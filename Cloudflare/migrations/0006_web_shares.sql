CREATE TABLE IF NOT EXISTS web_shares (
  source_id TEXT PRIMARY KEY NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  object_key TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_web_shares_expires_at
  ON web_shares (expires_at);
