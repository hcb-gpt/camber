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
  v_fallback_phone text;
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
    -- Phone available and not an owner: resolve via lookup (same as process-call)
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
    -- Guard 2 (expanded): No phone + sender_user_id is NOT a phone number
    v_contact_name := NULL;

  ELSIF v_contact_phone IS NULL
    AND NEW.sender_user_id IS NOT NULL
    AND looks_like_phone(NEW.sender_user_id) THEN
    -- Guard 2b: No contact_phone but sender_user_id contains a phone number.
    v_contact_phone := NEW.sender_user_id;
    SELECT lc.contact_id, lc.contact_name
    INTO v_contact_id, v_resolved_name
    FROM lookup_contact_by_phone(v_contact_phone) lc
    LIMIT 1;

    IF v_contact_id IS NOT NULL THEN
      v_contact_name := COALESCE(v_resolved_name, v_contact_name);
    END IF;

  ELSIF v_is_owner_phone THEN
    -- Guard 3: Phone matches owner_phones = shared line. Treat as unknown.
    v_contact_name  := NULL;
    v_contact_phone := NULL;
  END IF;

  -- =====================================================================
  -- NEW v4 FALLBACK RESOLUTION (only when contact still unresolved)
  -- =====================================================================
  IF v_contact_id IS NULL THEN

    -- Guard 4: beside_contact_id lookup
    IF NEW.beside_contact_id IS NOT NULL AND NEW.beside_contact_id != '' THEN
      SELECT sm.contact_phone
      INTO v_fallback_phone
      FROM sms_messages sm
      WHERE sm.beside_contact_id = NEW.beside_contact_id
        AND sm.contact_phone IS NOT NULL
        AND sm.contact_phone != ''
        AND sm.id != NEW.id
      ORDER BY sm.sent_at DESC
      LIMIT 1;

      IF v_fallback_phone IS NOT NULL THEN
        v_contact_phone := v_fallback_phone;
        SELECT lc.contact_id, lc.contact_name
        INTO v_contact_id, v_resolved_name
        FROM lookup_contact_by_phone(v_contact_phone) lc
        LIMIT 1;

        IF v_contact_id IS NOT NULL THEN
          v_contact_name := COALESCE(v_resolved_name, v_contact_name);
        END IF;
      END IF;
    END IF;

  END IF;

  IF v_contact_id IS NULL THEN

    -- Guard 5: Temporal proximity (outbound replies)
    IF NEW.direction = 'outbound' AND NEW.sent_at IS NOT NULL THEN
      SELECT i.contact_id, i.contact_name, i.contact_phone
      INTO v_contact_id, v_resolved_name, v_fallback_phone
      FROM interactions i
      WHERE i.channel = 'sms'
        AND i.contact_id IS NOT NULL
        AND i.event_at_utc >= (NEW.sent_at - interval '30 minutes')
        AND i.event_at_utc < NEW.sent_at
      ORDER BY i.event_at_utc DESC
      LIMIT 1;

      IF v_contact_id IS NOT NULL THEN
        v_contact_phone := COALESCE(v_contact_phone, v_fallback_phone);
        v_contact_name := COALESCE(v_contact_name, v_resolved_name);
      END IF;
    END IF;

  END IF;

  INSERT INTO public.calls_raw (
    interaction_id, channel, zap_version, thread_key, direction,
    other_party_name, other_party_phone, event_at_utc, summary,
    raw_snapshot_json, transcript, ingested_at_utc, inbox_id,
    source_received_at_utc, received_at_utc, capture_source, is_shadow
  )
  VALUES (
    v_interaction_id, 'sms', 'sms_bridge_v4', NEW.thread_id, NEW.direction,
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
    raw_snapshot_json       = EXCLUDED.raw_snapshot_json,
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
    v_interaction_id, 'sms', 'sms_bridge_v4',
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
