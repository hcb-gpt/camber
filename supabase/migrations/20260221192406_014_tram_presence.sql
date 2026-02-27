CREATE TABLE IF NOT EXISTS tram_presence (
  role                TEXT NOT NULL,
  origin_session      TEXT NOT NULL,
  origin_platform     TEXT,
  origin_client       TEXT,
  origin_agent        TEXT,
  capabilities_version TEXT,
  capabilities        TEXT,
  last_seen_at_utc    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  nonstandard_session BOOLEAN DEFAULT FALSE,
  PRIMARY KEY (role, origin_session)
);

CREATE INDEX IF NOT EXISTS idx_tram_presence_last_seen
  ON tram_presence (last_seen_at_utc);

CREATE INDEX IF NOT EXISTS idx_tram_presence_role
  ON tram_presence (role);

ALTER TABLE tram_presence ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'tram_presence' AND policyname = 'service_role_only'
  ) THEN
    CREATE POLICY service_role_only ON tram_presence
      FOR ALL USING ((SELECT auth.role()) = 'service_role');
  END IF;
END $$;

GRANT ALL ON tram_presence TO service_role;

CREATE OR REPLACE FUNCTION upsert_tram_presence(
  p_role                TEXT,
  p_origin_session      TEXT,
  p_origin_platform     TEXT DEFAULT NULL,
  p_origin_client       TEXT DEFAULT NULL,
  p_origin_agent        TEXT DEFAULT NULL,
  p_capabilities_version TEXT DEFAULT NULL,
  p_capabilities        TEXT DEFAULT NULL,
  p_nonstandard_session BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result JSONB;
BEGIN
  INSERT INTO tram_presence (
    role, origin_session, origin_platform, origin_client,
    origin_agent, capabilities_version, capabilities,
    last_seen_at_utc, nonstandard_session
  ) VALUES (
    p_role, p_origin_session, p_origin_platform, p_origin_client,
    p_origin_agent, p_capabilities_version, p_capabilities,
    NOW(), p_nonstandard_session
  )
  ON CONFLICT (role, origin_session) DO UPDATE SET
    origin_platform     = COALESCE(EXCLUDED.origin_platform, tram_presence.origin_platform),
    origin_client       = COALESCE(EXCLUDED.origin_client, tram_presence.origin_client),
    origin_agent        = COALESCE(EXCLUDED.origin_agent, tram_presence.origin_agent),
    capabilities_version = COALESCE(EXCLUDED.capabilities_version, tram_presence.capabilities_version),
    capabilities        = COALESCE(EXCLUDED.capabilities, tram_presence.capabilities),
    last_seen_at_utc    = NOW(),
    nonstandard_session = EXCLUDED.nonstandard_session
  RETURNING to_jsonb(tram_presence.*) INTO result;

  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_tram_presence TO service_role;

CREATE OR REPLACE FUNCTION tram_presence_online(
  p_threshold_minutes INTEGER DEFAULT 30,
  p_role              TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result JSONB;
BEGIN
  SELECT jsonb_agg(row_to_json(sub.*))
  INTO result
  FROM (
    SELECT *
    FROM tram_presence
    WHERE last_seen_at_utc >= NOW() - (p_threshold_minutes || ' minutes')::INTERVAL
      AND (p_role IS NULL OR role = p_role)
    ORDER BY last_seen_at_utc DESC
  ) sub;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION tram_presence_online TO service_role;;
