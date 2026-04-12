CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  secret_hash TEXT NOT NULL,
  team_name TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
