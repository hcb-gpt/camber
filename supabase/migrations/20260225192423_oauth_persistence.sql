-- 024_oauth_persistence.sql
-- Persist OAuth 2.1 client registrations and tokens to survive Cloud Run cold starts.
-- Fixes INFRA-004: browser clients forced to re-register and re-authorize on every cold start.

-- oauth_clients: DCR registrations
CREATE TABLE IF NOT EXISTS oauth_clients (
  client_id   TEXT PRIMARY KEY,
  client_secret TEXT,
  client_name TEXT NOT NULL DEFAULT 'Unknown Client',
  redirect_uris JSONB NOT NULL DEFAULT '[]'::jsonb,
  token_endpoint_auth_method TEXT NOT NULL DEFAULT 'none',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ
);

-- oauth_tokens: auth codes, access tokens, refresh tokens
CREATE TABLE IF NOT EXISTS oauth_tokens (
  token       TEXT PRIMARY KEY,
  token_type  TEXT NOT NULL CHECK (token_type IN ('auth_code', 'access_token', 'refresh_token')),
  client_id   TEXT NOT NULL REFERENCES oauth_clients(client_id) ON DELETE CASCADE,
  scope       TEXT DEFAULT 'mcp:tools',
  expires_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  redirect_uri   TEXT,
  code_challenge TEXT,
  linked_access_token TEXT
);

CREATE INDEX IF NOT EXISTS idx_oauth_tokens_client_id ON oauth_tokens(client_id);
CREATE INDEX IF NOT EXISTS idx_oauth_tokens_type ON oauth_tokens(token_type);
CREATE INDEX IF NOT EXISTS idx_oauth_tokens_expires ON oauth_tokens(expires_at);

-- RLS: service-role only (MCP server uses service key)
ALTER TABLE oauth_clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_tokens ENABLE ROW LEVEL SECURITY;;
