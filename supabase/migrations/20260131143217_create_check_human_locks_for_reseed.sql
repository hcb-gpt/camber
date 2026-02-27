-- Helper function for reseed: check human locks on active spans
-- Returns count of human-locked attributions for an interaction
-- Used by admin-reseed to enforce 409 before superseding

CREATE OR REPLACE FUNCTION check_human_locks_for_reseed(p_interaction_id text)
RETURNS TABLE (
  human_lock_count bigint,
  locked_span_ids uuid[]
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    count(*)::bigint as human_lock_count,
    array_agg(sa.span_id) as locked_span_ids
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id
  WHERE cs.interaction_id = p_interaction_id
    AND cs.is_superseded = false
    AND sa.attribution_lock = 'human';
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION check_human_locks_for_reseed(text) IS
  'Pre-reseed check: returns human lock count and span IDs. If count > 0, reseed must return 409.';;
