-- Update score_interaction to optionally save snapshot
-- p_save_snapshot: if true, insert a row into pipeline_scoreboard_snapshots

DROP FUNCTION IF EXISTS score_interaction(text);

CREATE OR REPLACE FUNCTION score_interaction(
  p_interaction_id text,
  p_save_snapshot boolean DEFAULT false
)
RETURNS TABLE (
  interaction_id text,
  gen_max int,
  spans_active int,
  attributions int,
  review_items int,
  review_gap int,
  override_reseeds int,
  status text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_gen_max int;
  v_spans_active int;
  v_attributions int;
  v_review_items int;
  v_review_gap int;
  v_override_reseeds int;
  v_status text;
  v_created_at timestamptz := now();
BEGIN
  -- Active spans
  SELECT COUNT(*)::int, COALESCE(MAX(cs.segment_generation), 0)::int
  INTO v_spans_active, v_gen_max
  FROM conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id
    AND cs.is_superseded = false;

  -- Attributions for active spans
  SELECT COUNT(*)::int
  INTO v_attributions
  FROM span_attributions sa
  WHERE sa.span_id IN (
    SELECT cs.id FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  );

  -- Review queue items for active spans
  SELECT COUNT(*)::int
  INTO v_review_items
  FROM review_queue rq
  WHERE rq.span_id IN (
    SELECT cs.id FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  );

  -- Review gap: needs_review but no review_queue row
  SELECT COUNT(*)::int
  INTO v_review_gap
  FROM span_attributions sa
  WHERE sa.span_id IN (
    SELECT cs.id FROM conversation_spans cs
    WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false
  )
  AND (sa.decision = 'review' OR sa.needs_review = true)
  AND NOT EXISTS (
    SELECT 1 FROM review_queue rq WHERE rq.span_id = sa.span_id
  );

  -- Override reseeds
  SELECT COUNT(*)::int
  INTO v_override_reseeds
  FROM override_log ol
  WHERE ol.interaction_id = p_interaction_id
    AND ol.entity_type = 'reseed';

  -- Determine status
  IF v_spans_active > 0 AND v_review_gap = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := 'FAIL';
  END IF;

  -- Optionally save snapshot
  IF p_save_snapshot THEN
    INSERT INTO pipeline_scoreboard_snapshots (
      interaction_id, gen_max, spans_active, attributions,
      review_items, review_gap, override_reseeds, status, created_at
    ) VALUES (
      p_interaction_id, v_gen_max, v_spans_active, v_attributions,
      v_review_items, v_review_gap, v_override_reseeds, v_status, v_created_at
    );
  END IF;

  -- Return result
  RETURN QUERY SELECT
    p_interaction_id,
    v_gen_max,
    v_spans_active,
    v_attributions,
    v_review_items,
    v_review_gap,
    v_override_reseeds,
    v_status,
    v_created_at;
END;
$$;;
