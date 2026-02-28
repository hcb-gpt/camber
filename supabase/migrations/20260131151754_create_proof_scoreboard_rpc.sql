-- Proof scoreboard RPC for push-button testing
-- Returns PASS/FAIL with all metrics in one call

CREATE OR REPLACE FUNCTION get_proof_scoreboard(p_interaction_id text)
RETURNS TABLE (
  interaction_id text,
  spans_total bigint,
  spans_active bigint,
  attributions bigint,
  review_pending bigint,
  reseed_count bigint,
  review_gap bigint,
  status text
) AS $$
BEGIN
  RETURN QUERY
  WITH active_spans AS (
    SELECT cs.id as span_id
    FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  ),
  gap AS (
    SELECT count(*) as cnt
    FROM span_attributions sa
    JOIN active_spans a ON a.span_id = sa.span_id
    LEFT JOIN review_queue rq ON rq.span_id = sa.span_id AND rq.status = 'pending'
    WHERE (sa.needs_review = true OR sa.decision = 'review')
      AND rq.id IS NULL
  )
  SELECT 
    p_interaction_id,
    (SELECT count(*) FROM conversation_spans cs WHERE cs.interaction_id = p_interaction_id)::bigint,
    (SELECT count(*) FROM active_spans)::bigint,
    (SELECT count(*) FROM span_attributions sa JOIN active_spans a ON a.span_id = sa.span_id)::bigint,
    (SELECT count(*) FROM review_queue rq JOIN active_spans a ON a.span_id = rq.span_id WHERE rq.status = 'pending')::bigint,
    (SELECT count(*) FROM override_log ol WHERE ol.entity_type = 'reseed' AND ol.interaction_id = p_interaction_id)::bigint,
    (SELECT cnt FROM gap)::bigint,
    CASE WHEN (SELECT cnt FROM gap) = 0 THEN 'PASS' ELSE 'FAIL' END;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_proof_scoreboard(text) IS
  'Push-button proof: returns PASS if review_gap=0, FAIL otherwise. Use for acceptance testing.';;
