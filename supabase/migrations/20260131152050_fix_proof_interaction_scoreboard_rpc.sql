
-- Fix: override_log uses entity_type='reseed', not action='reseed'

CREATE OR REPLACE FUNCTION proof_interaction_scoreboard(p_interaction_id text)
RETURNS TABLE (
  generation int,
  spans_total bigint,
  spans_active bigint,
  attributions bigint,
  review_queue_pending bigint,
  needs_review_flagged bigint,
  review_queue_gap bigint,
  override_reseeds bigint,
  status text
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  WITH all_spans AS (
    SELECT
      cs.id AS span_id,
      cs.segment_generation,
      cs.is_superseded
    FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id
  ),
  span_stats AS (
    SELECT
      COALESCE(MAX(segment_generation), 0)::int AS latest_generation,
      COUNT(*)::bigint AS spans_total,
      COUNT(*) FILTER (WHERE is_superseded = false)::bigint AS spans_active
    FROM all_spans
  ),
  active_spans AS (
    SELECT span_id FROM all_spans WHERE is_superseded = false
  ),
  attribution_stats AS (
    SELECT
      COUNT(*)::bigint AS attributions,
      COUNT(*) FILTER (WHERE sa.needs_review = true)::bigint AS needs_review_flagged
    FROM span_attributions sa
    WHERE sa.span_id IN (SELECT span_id FROM active_spans)
  ),
  review_stats AS (
    SELECT COUNT(*)::bigint AS review_queue_pending
    FROM review_queue rq
    WHERE rq.span_id IN (SELECT span_id FROM active_spans)
      AND rq.status = 'pending'
  ),
  gap_detector AS (
    SELECT COUNT(*)::bigint AS review_queue_gap
    FROM span_attributions sa
    WHERE sa.span_id IN (SELECT span_id FROM active_spans)
      AND sa.needs_review = true
      AND NOT EXISTS (
        SELECT 1 FROM review_queue rq
        WHERE rq.span_id = sa.span_id AND rq.status = 'pending'
      )
  ),
  override_stats AS (
    SELECT COUNT(*)::bigint AS override_reseeds
    FROM override_log ol
    WHERE ol.interaction_id = p_interaction_id
      AND ol.entity_type = 'reseed'
  )
  SELECT
    ss.latest_generation,
    ss.spans_total,
    ss.spans_active,
    COALESCE(ats.attributions, 0),
    COALESCE(rs.review_queue_pending, 0),
    COALESCE(ats.needs_review_flagged, 0),
    COALESCE(gd.review_queue_gap, 0),
    COALESCE(os.override_reseeds, 0),
    CASE
      WHEN ss.spans_active < 1 THEN 'FAIL: no active spans'
      WHEN COALESCE(ats.attributions, 0) < 1 THEN 'FAIL: no attributions'
      WHEN COALESCE(gd.review_queue_gap, 0) > 0 THEN 'FAIL: review_queue gap'
      ELSE 'PASS'
    END
  FROM span_stats ss
  CROSS JOIN attribution_stats ats
  CROSS JOIN review_stats rs
  CROSS JOIN gap_detector gd
  CROSS JOIN override_stats os;
END;
$$;
;
