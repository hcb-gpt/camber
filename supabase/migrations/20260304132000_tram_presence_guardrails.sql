-- Migration: tram_presence schema alignment and atomic register RPC

-- 1. Add missing model column (prevents 400 Bad Request drops)
ALTER TABLE public.tram_presence
  ADD COLUMN IF NOT EXISTS model TEXT;

-- 2. Add unique constraint to prevent split-brain duplicates for the same active session
-- We only enforce uniqueness on active sessions (where retired_at is null).
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_tram_presence 
ON public.tram_presence (origin_session, role) 
WHERE retired_at IS NULL;

-- 3. Update status view to expose model
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

-- Drop prior signatures
DROP FUNCTION IF EXISTS public.atomic_session_register(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT);
DROP FUNCTION IF EXISTS public.atomic_session_register(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT);

-- 4. Create Atomic Register RPC
CREATE OR REPLACE FUNCTION public.atomic_session_register(
    p_role TEXT,
    p_origin_session TEXT,
    p_origin_platform TEXT,
    p_origin_client TEXT,
    p_origin_agent TEXT DEFAULT NULL,
    p_platform_subtype TEXT DEFAULT NULL,
    p_capabilities_version TEXT DEFAULT NULL,
    p_capabilities TEXT DEFAULT NULL,
    p_capability_profile JSONB DEFAULT NULL,
    p_session_function TEXT DEFAULT NULL,
    p_model TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    result jsonb;
BEGIN
    IF p_role IS NULL OR p_origin_session IS NULL OR p_origin_platform IS NULL OR p_origin_client IS NULL THEN
        RAISE EXCEPTION 'role, origin_session, origin_platform, and origin_client are strictly required';
    END IF;

    INSERT INTO public.tram_presence (
        role, origin_session, origin_platform, origin_client, origin_agent,
        platform_subtype, capabilities_version, capabilities, capability_profile,
        session_function, model, booted_at, last_seen_at_utc, retired_at, retired_reason
    )
    VALUES (
        p_role, p_origin_session, p_origin_platform, p_origin_client, p_origin_agent,
        p_platform_subtype, p_capabilities_version, p_capabilities, p_capability_profile,
        p_session_function, p_model, NOW(), NOW(), NULL, NULL
    )
    ON CONFLICT (role, origin_session) DO UPDATE SET
        origin_platform      = EXCLUDED.origin_platform,
        origin_client        = EXCLUDED.origin_client,
        origin_agent         = COALESCE(EXCLUDED.origin_agent, public.tram_presence.origin_agent),
        platform_subtype     = COALESCE(EXCLUDED.platform_subtype, public.tram_presence.platform_subtype),
        capabilities_version = COALESCE(EXCLUDED.capabilities_version, public.tram_presence.capabilities_version),
        capabilities         = COALESCE(EXCLUDED.capabilities, public.tram_presence.capabilities),
        capability_profile   = COALESCE(EXCLUDED.capability_profile, public.tram_presence.capability_profile),
        session_function     = COALESCE(EXCLUDED.session_function, public.tram_presence.session_function),
        model                = COALESCE(EXCLUDED.model, public.tram_presence.model),
        last_seen_at_utc     = NOW(),
        retired_at           = NULL,
        retired_reason       = NULL
    RETURNING to_jsonb(public.tram_presence.*) INTO result;

    RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.atomic_session_register(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO service_role;
