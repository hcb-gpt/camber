-- Migration 20260305032000: Fix FOR_SESSION ACK governance trigger
--
-- Problems fixed:
-- 1) `blocked_ack_by` was always NULL because the trigger nulled NEW.ack_by
--    before building the governance flag payload.
-- 2) CEO-targeted messages (`for_session` contains "ceo") were being blocked
--    unconditionally, even when the ACK/claim actor was explicitly listed in
--    the FOR_SESSION allow-list.
--
-- This preserves the original intent ("don't intercept CEO messages") while
-- allowing allow-listed sessions to ACK/claim, and records the attempted ack
-- actor for audit/debugging.

CREATE OR REPLACE FUNCTION public.tram_enforce_for_session_ack()
RETURNS TRIGGER AS $$
DECLARE
  attempted_ack_by TEXT;
  target_sessions TEXT[];
  normalized_attempt TEXT;
  normalized_targets TEXT[];
BEGIN
  -- Only fires on ACK updates (acked changing from false/null to true)
  IF NEW.acked = true AND (OLD.acked IS NULL OR OLD.acked = false) THEN
    -- Only enforce the CEO intercept rule when the message is explicitly session-targeted.
    IF OLD.for_session IS NOT NULL AND BTRIM(OLD.for_session) <> '' AND OLD.for_session ~* 'ceo' THEN
      -- Capture attempted ack actor BEFORE we potentially null out NEW.ack_* fields.
      attempted_ack_by := NEW.ack_by;

      -- Split FOR_SESSION allow-list and normalize for case/whitespace.
      target_sessions := regexp_split_to_array(OLD.for_session, '\\s*,\\s*');
      normalized_targets := ARRAY(
        SELECT lower(BTRIM(value))
        FROM unnest(target_sessions) AS value
        WHERE BTRIM(value) <> ''
      );
      normalized_attempt := lower(BTRIM(COALESCE(attempted_ack_by, '')));

      -- Allow allow-listed sessions to ACK/claim even if the list includes CEO.
      IF normalized_attempt = '' OR NOT (normalized_attempt = ANY(normalized_targets)) THEN
        NEW.acked := false;
        NEW.acked_at := NULL;
        NEW.ack_by := NULL;
        NEW.ack_type := NULL;

        NEW.governance_flags := COALESCE(OLD.governance_flags, '[]'::jsonb) ||
          jsonb_build_array(jsonb_build_object(
            'rule', 'FOR_SESSION_ACK',
            'violation', format('ACK blocked: for_session=%s but ack attempted by %s', OLD.for_session, attempted_ack_by),
            'blocked_ack_by', attempted_ack_by,
            'detected_at', now()::text
          ));

        RETURN NEW;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Ensure trigger exists and references the updated function body.
DROP TRIGGER IF EXISTS trg_enforce_for_session_ack ON public.tram_messages;
CREATE TRIGGER trg_enforce_for_session_ack
  BEFORE UPDATE ON public.tram_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.tram_enforce_for_session_ack();

