-- Migration: Add model tracking to tram_presence

-- 1. Add column to base table
ALTER TABLE public.tram_presence
  ADD COLUMN IF NOT EXISTS model TEXT;

-- 2. Update the status view to expose the new column
CREATE OR REPLACE VIEW public.v_tram_presence_status AS
SELECT
  tp.role,
  tp.origin_session,
  tp.origin_platform,
  tp.origin_client,
  tp.origin_agent,
  tp.platform_subtype,
  tp.capabilities_version,
  tp.capabilities,
  tp.capability_profile,
  tp.session_function,
  tp.model,
  tp.nonstandard_session,
  tp.booted_at,
  tp.last_seen_at_utc,
  tp.retired_at,
  tp.retired_reason,
  tp.last_activity_kind,
  tp.last_activity_receipt,
  ROUND(EXTRACT(EPOCH FROM (NOW() - tp.last_seen_at_utc)) / 60.0, 1) AS age_minutes,
  CASE
    WHEN tp.retired_at IS NOT NULL THEN 'OFFLINE'::public.tram_presence_status_enum
    WHEN NOW() - tp.last_seen_at_utc <= INTERVAL '5 minutes' THEN 'ONLINE'::public.tram_presence_status_enum
    WHEN NOW() - tp.last_seen_at_utc <= INTERVAL '30 minutes' THEN 'IDLE'::public.tram_presence_status_enum
    WHEN NOW() - tp.last_seen_at_utc <= INTERVAL '120 minutes' THEN 'STALE'::public.tram_presence_status_enum
    ELSE 'OFFLINE'::public.tram_presence_status_enum
  END AS status_enum
FROM public.tram_presence tp;

GRANT SELECT ON public.v_tram_presence_status TO service_role;
