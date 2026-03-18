CREATE OR REPLACE FUNCTION public.atomic_retire_session(p_session_id text, p_reason text DEFAULT NULL::text, p_origin_epoch bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_presence tram_presence%ROWTYPE;
  v_reset_count INTEGER := 0;
  v_session JSONB;
BEGIN
  SELECT *
    INTO v_presence
    FROM public.tram_presence
   WHERE origin_session = p_session_id
     AND retired_at IS NULL
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'retired', FALSE,
      'reason', 'not_found'
    );
  END IF;

  IF v_presence.retired_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'retired', FALSE,
      'reason', 'already_retired',
      'authority_epoch', COALESCE(v_presence.authority_epoch, 0),
      'lease_state', COALESCE(v_presence.lease_state, 'finalized')
    );
  END IF;

  IF p_origin_epoch IS NOT NULL
     AND COALESCE(v_presence.authority_epoch, 0) <> p_origin_epoch
  THEN
    RETURN jsonb_build_object(
      'retired', FALSE,
      'reason', 'stale_origin_epoch',
      'authority_epoch', COALESCE(v_presence.authority_epoch, 0),
      'lease_state', COALESCE(v_presence.lease_state, 'active')
    );
  END IF;

  UPDATE public.tram_presence
     SET retired_at = NOW(),
         retired_reason = p_reason,
         authority_revoked_at = NOW(),
         lease_state = 'finalized',
         last_authoritative_update_at = NOW()
   WHERE origin_session = p_session_id
     AND retired_at IS NULL
   RETURNING to_jsonb(public.tram_presence.*) INTO v_session;

  UPDATE public.tram_messages
     SET acked    = FALSE,
         acked_at = NULL,
         ack_by   = NULL,
         ack_type = NULL,
         ack_note = NULL
   WHERE ack_by     ILIKE p_session_id
     AND acked      = TRUE
     AND resolution IS NULL;

  GET DIAGNOSTICS v_reset_count = ROW_COUNT;

  UPDATE public.tram_claims
     SET claim_state = 'RELEASED',
         released_at = NOW(),
         release_reason = 'SESSION_RETIRED'
   WHERE claimed_by_session = p_session_id
     AND released_at IS NULL
     AND claim_state = 'ACTIVE';

  RETURN jsonb_build_object(
    'retired', TRUE,
    'orphaned_work', v_reset_count,
    'authority_epoch', COALESCE((v_session->>'authority_epoch')::BIGINT, 0),
    'lease_state', COALESCE(v_session->>'lease_state', 'finalized'),
    'session', v_session
  );
END;
$function$;
