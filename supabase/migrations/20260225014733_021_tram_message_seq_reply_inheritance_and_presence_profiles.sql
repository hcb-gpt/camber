-- Migration 021: TRAM vnext — message_seq ordering, reply inheritance, and presence profiles
-- All changes are additive + idempotent.

-- ============================================================
-- A. message_seq column + backfill (tram_messages)
-- ============================================================

ALTER TABLE public.tram_messages
  ADD COLUMN IF NOT EXISTS message_seq BIGINT;

-- Ensure a sequence-backed default exists when message_seq is a plain column
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'tram_messages'
      AND a.attname = 'message_seq'
      AND a.attidentity = ''
  ) THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'tram_messages'
        AND a.attname = 'message_seq'
    ) THEN
      CREATE SEQUENCE IF NOT EXISTS public.tram_message_seq;
      ALTER TABLE public.tram_messages
        ALTER COLUMN message_seq SET DEFAULT nextval('public.tram_message_seq');
    END IF;
  END IF;
END
$$;

-- Backfill any NULL message_seq values deterministically (created_at, receipt).
WITH max_seq AS (
  SELECT COALESCE(MAX(message_seq), 0) AS base
  FROM public.tram_messages
),
missing AS (
  SELECT
    receipt,
    row_number() OVER (ORDER BY created_at, receipt) AS rn
  FROM public.tram_messages
  WHERE message_seq IS NULL
)
UPDATE public.tram_messages m
SET message_seq = (SELECT base FROM max_seq) + missing.rn
FROM missing
WHERE m.receipt = missing.receipt;

-- If message_seq is backed by a serial/identity sequence, bump it to max.
DO $$
DECLARE
  seq_name text;
  max_val bigint;
BEGIN
  seq_name := pg_get_serial_sequence('public.tram_messages', 'message_seq');
  SELECT COALESCE(MAX(message_seq), 0) INTO max_val FROM public.tram_messages;

  IF seq_name IS NOT NULL THEN
    PERFORM setval(seq_name, max_val);
  ELSIF to_regclass('public.tram_message_seq') IS NOT NULL THEN
    PERFORM setval('public.tram_message_seq', max_val);
  END IF;
END
$$;

-- Enforce non-null once backfill is complete.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'tram_messages'
      AND column_name = 'message_seq'
      AND is_nullable = 'YES'
  ) AND (SELECT COUNT(*) FROM public.tram_messages WHERE message_seq IS NULL) = 0 THEN
    ALTER TABLE public.tram_messages
      ALTER COLUMN message_seq SET NOT NULL;
  END IF;
END
$$;

-- ============================================================
-- B. Indexes for 10x volume readiness
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_tram_messages_in_reply_to
  ON public.tram_messages (in_reply_to)
  WHERE in_reply_to IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tram_messages_corr_message_seq
  ON public.tram_messages (correlation_id, message_seq DESC)
  WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tram_messages_to_acked_message_seq
  ON public.tram_messages ("to", acked, message_seq DESC);

CREATE INDEX IF NOT EXISTS idx_tram_messages_to_kind_message_seq
  ON public.tram_messages ("to", kind, message_seq DESC);

CREATE INDEX IF NOT EXISTS idx_tram_messages_for_session_message_seq
  ON public.tram_messages (for_session, message_seq DESC)
  WHERE for_session IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tram_messages_expires_at
  ON public.tram_messages (expires_at)
  WHERE expires_at IS NOT NULL;

-- ============================================================
-- C. Reply inheritance trigger (thread + correlation_id)
-- ============================================================

CREATE OR REPLACE FUNCTION public.tram_inherit_reply_context()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  parent_correlation_id text;
  parent_thread text;
BEGIN
  IF NEW.in_reply_to IS NULL OR NEW.in_reply_to = '' THEN
    RETURN NEW;
  END IF;

  SELECT m.correlation_id, m.thread
  INTO parent_correlation_id, parent_thread
  FROM public.tram_messages m
  WHERE m.receipt = NEW.in_reply_to
  LIMIT 1;

  IF NEW.correlation_id IS NULL AND parent_correlation_id IS NOT NULL THEN
    NEW.correlation_id := parent_correlation_id;
  END IF;

  IF (NEW.thread IS NULL OR NEW.thread = '') AND parent_thread IS NOT NULL THEN
    NEW.thread := parent_thread;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tram_inherit_reply_context ON public.tram_messages;
CREATE TRIGGER trg_tram_inherit_reply_context
  BEFORE INSERT ON public.tram_messages
  FOR EACH ROW EXECUTE FUNCTION public.tram_inherit_reply_context();

-- ============================================================
-- D. Presence profiles (tram_presence)
-- ============================================================

ALTER TABLE public.tram_presence
  ADD COLUMN IF NOT EXISTS last_activity_kind TEXT,
  ADD COLUMN IF NOT EXISTS last_activity_receipt TEXT,
  ADD COLUMN IF NOT EXISTS platform_subtype TEXT,
  ADD COLUMN IF NOT EXISTS capability_profile JSONB;

CREATE INDEX IF NOT EXISTS idx_tram_presence_last_activity_kind
  ON public.tram_presence (last_activity_kind);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE t.typname = 'tram_presence_status_enum'
      AND n.nspname = 'public'
  ) THEN
    CREATE TYPE public.tram_presence_status_enum AS ENUM ('ONLINE', 'IDLE', 'STALE', 'OFFLINE');
  END IF;
END
$$;

-- Update derived status view to include new columns (additive).
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

-- Extend upsert_tram_presence RPC (backwards compatible).
DROP FUNCTION IF EXISTS public.upsert_tram_presence(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN
);

CREATE OR REPLACE FUNCTION public.upsert_tram_presence(
  p_role                TEXT,
  p_origin_session      TEXT,
  p_origin_platform     TEXT DEFAULT NULL,
  p_origin_client       TEXT DEFAULT NULL,
  p_origin_agent        TEXT DEFAULT NULL,
  p_capabilities_version TEXT DEFAULT NULL,
  p_capabilities        TEXT DEFAULT NULL,
  p_nonstandard_session BOOLEAN DEFAULT FALSE,
  p_platform_subtype    TEXT DEFAULT NULL,
  p_capability_profile  JSONB DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result JSONB;
BEGIN
  INSERT INTO public.tram_presence (
    role, origin_session, origin_platform, origin_client,
    origin_agent, platform_subtype, capabilities_version, capabilities,
    capability_profile, last_seen_at_utc, nonstandard_session,
    booted_at, retired_at, retired_reason
  ) VALUES (
    p_role, p_origin_session, p_origin_platform, p_origin_client,
    p_origin_agent, p_platform_subtype, p_capabilities_version, p_capabilities,
    p_capability_profile, NOW(), p_nonstandard_session,
    NOW(), NULL, NULL
  )
  ON CONFLICT (role, origin_session) DO UPDATE SET
    origin_platform      = COALESCE(EXCLUDED.origin_platform, public.tram_presence.origin_platform),
    origin_client        = COALESCE(EXCLUDED.origin_client, public.tram_presence.origin_client),
    origin_agent         = COALESCE(EXCLUDED.origin_agent, public.tram_presence.origin_agent),
    platform_subtype     = COALESCE(EXCLUDED.platform_subtype, public.tram_presence.platform_subtype),
    capabilities_version = COALESCE(EXCLUDED.capabilities_version, public.tram_presence.capabilities_version),
    capabilities         = COALESCE(EXCLUDED.capabilities, public.tram_presence.capabilities),
    capability_profile   = COALESCE(EXCLUDED.capability_profile, public.tram_presence.capability_profile),
    last_seen_at_utc     = NOW(),
    nonstandard_session  = EXCLUDED.nonstandard_session,
    booted_at            = NOW(),
    retired_at           = NULL,
    retired_reason       = NULL
  RETURNING to_jsonb(public.tram_presence.*) INTO result;

  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_tram_presence TO service_role;;
