-- score_interaction(interaction_id text)
-- Returns single-row scoreboard for one interaction
-- Used by shadow_batch_replay.sh and eval_harness

CREATE OR REPLACE FUNCTION score_interaction(p_interaction_id text)
RETURNS TABLE (
  interaction_id text,
  gen_max int,
  spans_active int,
  attributions int,
  review_items int,
  review_gap int,
  override_reseeds int,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  WITH active_spans AS (
    SELECT
      cs.id AS span_id,
      cs.segment_generation AS generation
    FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id
      AND cs.is_superseded = false
  ),
  
  gen_max AS (
    SELECT COALESCE(MAX(generation), 0) AS val FROM active_spans
  ),
  
  attributions AS (
    SELECT COUNT(*)::int AS val
    FROM span_attributions sa
    WHERE sa.span_id IN (SELECT span_id FROM active_spans)
  ),
  
  review_items AS (
    SELECT COUNT(*)::int AS val
    FROM review_queue rq
    WHERE rq.span_id IN (SELECT span_id FROM active_spans)
  ),
  
  needs_review_spans AS (
    SELECT DISTINCT sa.span_id
    FROM span_attributions sa
    WHERE sa.span_id IN (SELECT span_id FROM active_spans)
      AND (sa.decision = 'review' OR sa.needs_review = true)
  ),
  
  review_gaps AS (
    SELECT n.span_id
    FROM needs_review_spans n
    LEFT JOIN review_queue rq ON rq.span_id = n.span_id
    WHERE rq.id IS NULL
  ),
  
  override_reseeds AS (
    SELECT COUNT(*)::int AS val
    FROM override_log ol
    WHERE ol.interaction_id = p_interaction_id
      AND ol.entity_type = 'reseed'
  )
  
  SELECT
    p_interaction_id AS interaction_id,
    (SELECT val FROM gen_max)::int AS gen_max,
    (SELECT COUNT(*) FROM active_spans)::int AS spans_active,
    (SELECT val FROM attributions) AS attributions,
    (SELECT val FROM review_items) AS review_items,
    (SELECT COUNT(*) FROM review_gaps)::int AS review_gap,
    (SELECT val FROM override_reseeds) AS override_reseeds,
    NOW() AS created_at;
$$;;
