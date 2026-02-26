-- v2.9.1: SMS bridge contact resolution + owner-name guard
--
-- Problem: bridge_sms_message_to_surfaces copies contact_name verbatim from
-- sms_messages with ZERO contact resolution. When Beside can't resolve a
-- sender (contact_phone=null, sender_user_id='unknown'), it falls back to
-- the account owner name — causing Jimmy Chastain's texts to appear as
-- "Chad Barlow".
--
-- Fix (three guards):
-- 1. When contact_phone is available AND not an owner phone: resolve via
--    lookup_contact_by_phone (same path as process-call) and set contact_id.
-- 2. When contact_phone is NULL and sender_user_id='unknown': suppress the
--    contact_name (Beside's owner-name fallback is not trustworthy).
-- 3. When contact_phone matches owner_phones: treat as unknown sender.
--
-- Also bumps zap_version from 'sms_bridge_v1' to 'sms_bridge_v2'.
-- Also backfills contact_id on all existing SMS interactions.

-----------------------------------------------------------------------
-- PART 1: Replace the trigger function with contact resolution
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bridge_sms_message_to_surfaces()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_interaction_id text;
  v_ingested_at_utc timestamptz;
  v_contact_id uuid;
  v_resolved_name text;
  v_contact_name text;
  v_contact_phone text;
  v_is_owner_phone boolean := false;
BEGIN
  v_interaction_id := 'sms_' || COALESCE(NULLIF(NEW.message_id, ''), NEW.id::text);
  v_ingested_at_utc := COALESCE(NEW.ingested_at, now());

  v_contact_phone := NEW.contact_phone;
  v_contact_name  := NEW.contact_name;

  -- Guard 1: Check if contact_phone is an owner phone (shared-line defense)
  IF v_contact_phone IS NOT NULL AND v_contact_phone != '' THEN
    SELECT EXISTS (
      SELECT 1 FROM owner_phones
      WHERE phone_number = v_contact_phone
        AND active = true
    ) INTO v_is_owner_phone;
  END IF;

  IF v_contact_phone IS NOT NULL AND v_contact_phone != '' AND NOT v_is_owner_phone THEN
    -- Phone available and not an owner: resolve via lookup (same as process-call)
    SELECT lc.contact_id, lc.contact_name
    INTO v_contact_id, v_resolved_name
    FROM lookup_contact_by_phone(v_contact_phone) lc
    LIMIT 1;

    IF v_contact_id IS NOT NULL THEN
      v_contact_name := COALESCE(v_resolved_name, v_contact_name);
    END IF;

  ELSIF v_contact_phone IS NULL AND NEW.sender_user_id = 'unknown' THEN
    -- Guard 2: No phone + unknown sender = Beside owner-name fallback. Suppress.
    v_contact_name := NULL;

  ELSIF v_is_owner_phone THEN
    -- Guard 3: Phone matches owner_phones = shared line. Treat as unknown.
    v_contact_name  := NULL;
    v_contact_phone := NULL;
  END IF;

  INSERT INTO public.calls_raw (
    interaction_id, channel, zap_version, thread_key, direction,
    other_party_name, other_party_phone, event_at_utc, summary,
    raw_snapshot_json, transcript, ingested_at_utc, inbox_id,
    source_received_at_utc, received_at_utc, capture_source, is_shadow
  )
  VALUES (
    v_interaction_id, 'sms', 'sms_bridge_v2', NEW.thread_id, NEW.direction,
    v_contact_name, v_contact_phone,
    COALESCE(NEW.sent_at, v_ingested_at_utc),
    left(COALESCE(NEW.content, ''), 280),
    to_jsonb(NEW), NEW.content, v_ingested_at_utc, NEW.sender_inbox_id,
    NEW.sent_at, v_ingested_at_utc, 'sms_bridge_trigger', false
  )
  ON CONFLICT (interaction_id) DO UPDATE SET
    thread_key             = EXCLUDED.thread_key,
    direction              = EXCLUDED.direction,
    other_party_name       = EXCLUDED.other_party_name,
    other_party_phone      = EXCLUDED.other_party_phone,
    event_at_utc           = EXCLUDED.event_at_utc,
    summary                = EXCLUDED.summary,
    raw_snapshot_json      = EXCLUDED.raw_snapshot_json,
    transcript             = EXCLUDED.transcript,
    ingested_at_utc        = EXCLUDED.ingested_at_utc,
    inbox_id               = EXCLUDED.inbox_id,
    source_received_at_utc = EXCLUDED.source_received_at_utc,
    received_at_utc        = EXCLUDED.received_at_utc,
    capture_source         = EXCLUDED.capture_source;

  INSERT INTO public.interactions (
    interaction_id, channel, source_zap, contact_name, contact_phone,
    contact_id, thread_key, event_at_utc, ingested_at_utc,
    human_summary, transcript_chars, is_shadow
  )
  VALUES (
    v_interaction_id, 'sms', 'sms_bridge_v2',
    v_contact_name, v_contact_phone, v_contact_id,
    NEW.thread_id,
    COALESCE(NEW.sent_at, v_ingested_at_utc),
    v_ingested_at_utc,
    left(COALESCE(NEW.content, ''), 280),
    char_length(COALESCE(NEW.content, '')),
    false
  )
  ON CONFLICT (interaction_id) DO UPDATE SET
    contact_name     = EXCLUDED.contact_name,
    contact_phone    = EXCLUDED.contact_phone,
    contact_id       = EXCLUDED.contact_id,
    thread_key       = EXCLUDED.thread_key,
    event_at_utc     = EXCLUDED.event_at_utc,
    ingested_at_utc  = EXCLUDED.ingested_at_utc,
    human_summary    = EXCLUDED.human_summary,
    transcript_chars = EXCLUDED.transcript_chars;

  RETURN NEW;
END;
$function$;

-----------------------------------------------------------------------
-- PART 2: Backfill contact_id on existing SMS interactions
-- (phone available + not owner phone → resolve via lookup)
-----------------------------------------------------------------------
WITH sms_to_resolve AS (
  SELECT i.interaction_id, i.contact_phone
  FROM interactions i
  WHERE i.channel = 'sms'
    AND i.contact_id IS NULL
    AND i.contact_phone IS NOT NULL
    AND i.contact_phone != ''
    AND NOT EXISTS (
      SELECT 1 FROM owner_phones op
      WHERE op.phone_number = i.contact_phone AND op.active = true
    )
),
resolved AS (
  SELECT
    s.interaction_id,
    lc.contact_id AS resolved_contact_id,
    lc.contact_name AS resolved_name
  FROM sms_to_resolve s,
  LATERAL lookup_contact_by_phone(s.contact_phone) lc
  WHERE lc.contact_id IS NOT NULL
)
UPDATE interactions i
SET contact_id   = r.resolved_contact_id,
    contact_name = COALESCE(r.resolved_name, i.contact_name)
FROM resolved r
WHERE i.interaction_id = r.interaction_id;

-----------------------------------------------------------------------
-- PART 3: Suppress "Chad Barlow" name on mislabeled SMS interactions
-- (contact_phone IS NULL + sender_user_id = 'unknown' in source data)
-----------------------------------------------------------------------
UPDATE interactions i
SET contact_name = NULL
FROM sms_messages sm
WHERE i.interaction_id = 'sms_' || COALESCE(NULLIF(sm.message_id, ''), sm.id::text)
  AND i.channel = 'sms'
  AND sm.contact_phone IS NULL
  AND sm.sender_user_id = 'unknown'
  AND i.contact_name IS NOT NULL;

-- Also fix calls_raw other_party_name for the same rows
UPDATE calls_raw cr
SET other_party_name = NULL
FROM sms_messages sm
WHERE cr.interaction_id = 'sms_' || COALESCE(NULLIF(sm.message_id, ''), sm.id::text)
  AND cr.channel = 'sms'
  AND sm.contact_phone IS NULL
  AND sm.sender_user_id = 'unknown'
  AND cr.other_party_name IS NOT NULL;
