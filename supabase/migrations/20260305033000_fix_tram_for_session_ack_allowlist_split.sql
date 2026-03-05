-- Migration 20260305033000: Fix FOR_SESSION allow-list parsing for CEO ACK enforcement
--
-- Follow-up to 20260305032000: our regexp-based split pattern used an over-escaped
-- `\\s` sequence, which prevented splitting and caused false blocks even when
-- `ack_by` was allow-listed. Switch to comma split + trim for deterministic behavior.

CREATE OR REPLACE FUNCTION public.tram_enforce_for_session_ack()
RETURNS TRIGGER AS $$
DECLARE
  attempted_ack_by TEXT;
  target_sessions TEXT[];
  normalized_attempt TEXT;
  normalized_targets TEXT[];
BEGIN
  IF NEW.acked = true AND (OLD.acked IS NULL OR OLD.acked = false) THEN
    IF OLD.for_session IS NOT NULL AND BTRIM(OLD.for_session) <> '' AND OLD.for_session ~* 'ceo' THEN
      attempted_ack_by := NEW.ack_by;

      -- Split on commas (FOR_SESSION is stored as comma-separated tokens).
      target_sessions := string_to_array(OLD.for_session, ',');
      normalized_targets := ARRAY(
        SELECT lower(BTRIM(value))
        FROM unnest(target_sessions) AS value
        WHERE BTRIM(value) <> ''
      );
      normalized_attempt := lower(BTRIM(COALESCE(attempted_ack_by, '')));

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

