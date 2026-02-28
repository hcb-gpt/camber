ALTER TABLE tram_presence ADD COLUMN IF NOT EXISTS booted_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE tram_presence ADD COLUMN IF NOT EXISTS retired_at TIMESTAMPTZ;
ALTER TABLE tram_presence ADD COLUMN IF NOT EXISTS retired_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_tram_presence_active
  ON tram_presence (role, origin_session)
  WHERE retired_at IS NULL;

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
    last_seen_at_utc, nonstandard_session, booted_at, retired_at, retired_reason
  ) VALUES (
    p_role, p_origin_session, p_origin_platform, p_origin_client,
    p_origin_agent, p_capabilities_version, p_capabilities,
    NOW(), p_nonstandard_session, NOW(), NULL, NULL
  )
  ON CONFLICT (role, origin_session) DO UPDATE SET
    origin_platform     = COALESCE(EXCLUDED.origin_platform, tram_presence.origin_platform),
    origin_client       = COALESCE(EXCLUDED.origin_client, tram_presence.origin_client),
    origin_agent        = COALESCE(EXCLUDED.origin_agent, tram_presence.origin_agent),
    capabilities_version = COALESCE(EXCLUDED.capabilities_version, tram_presence.capabilities_version),
    capabilities        = COALESCE(EXCLUDED.capabilities, tram_presence.capabilities),
    last_seen_at_utc    = NOW(),
    nonstandard_session = EXCLUDED.nonstandard_session,
    booted_at           = NOW(),
    retired_at          = NULL,
    retired_reason      = NULL
  RETURNING to_jsonb(tram_presence.*) INTO result;

  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION upsert_tram_presence TO service_role;

CREATE OR REPLACE FUNCTION check_session_conflict(
  p_role              TEXT,
  p_origin_session    TEXT,
  p_threshold_minutes INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing JSONB;
BEGIN
  SELECT to_jsonb(tp.*)
  INTO existing
  FROM tram_presence tp
  WHERE tp.role = p_role
    AND tp.origin_session = p_origin_session
    AND tp.retired_at IS NULL
    AND tp.last_seen_at_utc >= NOW() - (p_threshold_minutes || ' minutes')::INTERVAL;

  IF existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'conflict', true,
      'existing', existing
    );
  END IF;

  RETURN jsonb_build_object('conflict', false);
END;
$$;

GRANT EXECUTE ON FUNCTION check_session_conflict TO service_role;

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
      AND retired_at IS NULL
      AND (p_role IS NULL OR role = p_role)
    ORDER BY last_seen_at_utc DESC
  ) sub;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION tram_presence_online TO service_role;;
