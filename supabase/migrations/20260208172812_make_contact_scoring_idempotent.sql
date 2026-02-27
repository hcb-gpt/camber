
-- Replace trigger function with idempotent version
CREATE OR REPLACE FUNCTION public.update_contact_interaction_stats()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_already_scored boolean;
BEGIN
  IF NEW.contact_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Attempt to insert into scoring log (dedup check)
  BEGIN
    INSERT INTO contact_scoring_log (contact_id, interaction_id, transcript_chars)
    VALUES (NEW.contact_id, NEW.interaction_id, COALESCE(NEW.transcript_chars, 0));
    
    v_already_scored := false;
  EXCEPTION WHEN unique_violation THEN
    v_already_scored := true;
  END;

  IF v_already_scored THEN
    -- Log the suppression for audit trail
    INSERT INTO contact_scoring_suppressions (contact_id, interaction_id, reason)
    VALUES (NEW.contact_id, NEW.interaction_id, 'duplicate_interaction');
    
    -- Do NOT increment stats
    RETURN NEW;
  END IF;

  -- First time scoring this contact for this interaction — increment stats
  UPDATE contacts SET
    interaction_count = COALESCE(interaction_count, 0) + 1,
    last_interaction_at = GREATEST(COALESCE(last_interaction_at, '1970-01-01'::timestamptz), NEW.event_at_utc),
    total_transcript_chars = COALESCE(total_transcript_chars, 0) + COALESCE(NEW.transcript_chars, 0),
    updated_at = now()
  WHERE id = NEW.contact_id;

  RETURN NEW;
END;
$$;
;
