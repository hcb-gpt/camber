-- PART 1: looks_like_phone() helper
CREATE OR REPLACE FUNCTION public.looks_like_phone(p_val text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT length(regexp_replace(COALESCE(p_val, ''), '[^0-9]', '', 'g')) >= 7;
$$;

-- PART 2: owner_names config table
CREATE TABLE IF NOT EXISTS public.owner_names (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_owner_names_lower_active
  ON public.owner_names (lower(trim(name)))
  WHERE active = true;

INSERT INTO public.owner_names (name)
VALUES ('Chad Barlow')
ON CONFLICT ((lower(trim(name)))) WHERE active = true DO NOTHING;

-- PART 3: Bridge trigger v3
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

  -- Guard 0: Suppress contact_name if it matches a known admin/owner name
  IF v_contact_name IS NOT NULL AND EXISTS (
    SELECT 1 FROM owner_names
    WHERE lower(trim(name)) = lower(trim(v_contact_name))
      AND active = true
  ) THEN
    v_contact_name := NULL;
  END IF;

  -- Guard 1: Check if contact_phone is an owner phone (shared-line defense)
  IF v_contact_phone IS NOT NULL AND v_contact_phone != '' THEN
    SELECT EXISTS (
      SELECT 1 FROM owner_phones
      WHERE phone = v_contact_phone
        AND active = true
    ) INTO v_is_owner_phone;
  END IF;

  IF v_contact_phone IS NOT NULL AND v_contact_phone != '' AND NOT v_is_owner_phone THEN
    SELECT lc.contact_id, lc.contact_name
    INTO v_contact_id, v_resolved_name
    FROM lookup_contact_by_phone(v_contact_phone) lc
    LIMIT 1;

    IF v_contact_id IS NOT NULL THEN
      v_contact_name := COALESCE(v_resolved_name, v_contact_name);
    END IF;

  ELSIF v_contact_phone IS NULL
    AND NEW.sender_user_id IS NOT NULL
    AND NOT looks_like_phone(NEW.sender_user_id) THEN
    -- Guard 2 (expanded): sender_user_id is NOT a phone number
    v_contact_name := NULL;

  ELSIF v_contact_phone IS NULL
    AND NEW.sender_user_id IS NOT NULL
    AND looks_like_phone(NEW.sender_user_id) THEN
    -- Guard 2b: sender_user_id contains a phone; reverse lookup
    v_contact_phone := NEW.sender_user_id;
    SELECT lc.contact_id, lc.contact_name
    INTO v_contact_id, v_resolved_name
    FROM lookup_contact_by_phone(v_contact_phone) lc
    LIMIT 1;

    IF v_contact_id IS NOT NULL THEN
      v_contact_name := COALESCE(v_resolved_name, v_contact_name);
    END IF;

  ELSIF v_is_owner_phone THEN
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
    v_interaction_id, 'sms', 'sms_bridge_v3', NEW.thread_id, NEW.direction,
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
    v_interaction_id, 'sms', 'sms_bridge_v3',
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
$function$;;
