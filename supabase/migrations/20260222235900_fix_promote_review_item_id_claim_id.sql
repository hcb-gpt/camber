-- Fix consolidation promotion REVIEW lane item_id mapping.
-- Root cause: promote_journal_claims_to_belief wrote journal_claims.id into
-- journal_review_queue.item_id, but orphan-stopline trigger validates against
-- journal_claims.claim_id.

DO $$
DECLARE
  v_def text;
  v_old_snippet text := E'''claim'',\n        v_claim.id,';
  v_new_snippet text := E'''claim'',\n        v_claim.claim_id,';
BEGIN
  SELECT pg_get_functiondef('public.promote_journal_claims_to_belief(uuid)'::regprocedure)
  INTO v_def;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'promote_journal_claims_to_belief(uuid) not found';
  END IF;

  IF position(v_new_snippet IN v_def) > 0 THEN
    RAISE NOTICE 'promote_journal_claims_to_belief already patched';
    RETURN;
  END IF;

  IF position(v_old_snippet IN v_def) = 0 THEN
    RAISE EXCEPTION 'expected REVIEW lane snippet not found; aborting rewrite';
  END IF;

  v_def := replace(v_def, v_old_snippet, v_new_snippet);
  EXECUTE v_def;
END;
$$;
