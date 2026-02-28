-- Review coverage check for interaction
-- Per STRAT TURN:67 taskpack=db_safety_for_review_queue

CREATE OR REPLACE FUNCTION get_review_coverage(p_interaction_id text)
RETURNS TABLE (
  interaction_id text,
  active_spans bigint,
  attributed_spans bigint,
  needs_review_spans bigint,
  review_queue_items bigint,
  coverage_gap bigint,
  gap_span_ids uuid[]
) AS $$
BEGIN
  RETURN QUERY
  WITH active AS (
    SELECT cs.id as span_id
    FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id
      AND cs.is_superseded = false
  ),
  needs_review AS (
    SELECT sa.span_id
    FROM span_attributions sa
    JOIN active a ON a.span_id = sa.span_id
    WHERE sa.needs_review = true OR sa.decision = 'review'
  ),
  in_queue AS (
    SELECT rq.span_id
    FROM review_queue rq
    JOIN active a ON a.span_id = rq.span_id
    WHERE rq.status IN ('pending', 'in_progress')
  ),
  gaps AS (
    SELECT nr.span_id
    FROM needs_review nr
    LEFT JOIN in_queue iq ON iq.span_id = nr.span_id
    WHERE iq.span_id IS NULL
  )
  SELECT 
    p_interaction_id as interaction_id,
    (SELECT count(*) FROM active)::bigint as active_spans,
    (SELECT count(DISTINCT sa.span_id) FROM span_attributions sa JOIN active a ON a.span_id = sa.span_id)::bigint as attributed_spans,
    (SELECT count(*) FROM needs_review)::bigint as needs_review_spans,
    (SELECT count(*) FROM in_queue)::bigint as review_queue_items,
    (SELECT count(*) FROM gaps)::bigint as coverage_gap,
    (SELECT array_agg(span_id) FROM gaps) as gap_span_ids;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_review_coverage(text) IS
  'Returns review coverage metrics: active spans, needs_review count, review_queue count, and gap (spans needing review but not queued)';;
