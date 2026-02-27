-- Phase 1: Throttle upsert_tram_presence to skip updates within 60s
-- Prevents write-amplification during tool-call storms
-- Thread: tram-vnext

CREATE OR REPLACE FUNCTION upsert_tram_presence(
  p_role TEXT,
  p_origin_session TEXT,
  p_origin_platform TEXT DEFAULT NULL,
  p_origin_client TEXT DEFAULT NULL,
  p_origin_agent TEXT DEFAULT NULL,
  p_capabilities_version TEXT DEFAULT NULL,
  p_capabilities TEXT DEFAULT NULL,
  p_nonstandard_session BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  result JSONB;
  existing RECORD;
BEGIN
  -- Throttle: if row exists, is not retired, and was seen < 60s ago, skip the write
  SELECT * INTO existing
  FROM tram_presence
  WHERE role = p_role AND origin_session = p_origin_session;

  IF FOUND
     AND existing.retired_at IS NULL
     AND existing.last_seen_at_utc > NOW() - INTERVAL '60 seconds'
  THEN
    RETURN to_jsonb(existing);
  END IF;

  -- Full upsert (new row, retired row being revived, or stale heartbeat)
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
    booted_at           = CASE
                            WHEN tram_presence.retired_at IS NOT NULL THEN NOW()
                            ELSE tram_presence.booted_at
                          END,
    retired_at          = NULL,
    retired_reason      = NULL
  RETURNING to_jsonb(tram_presence.*) INTO result;

  RETURN result;
END;
$$;
;
