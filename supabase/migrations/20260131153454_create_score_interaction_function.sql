-- Canonical score_interaction function per STRAT naming convention
-- Wraps get_proof_scoreboard with optional snapshot insert

CREATE OR REPLACE FUNCTION score_interaction(
  p_interaction_id text,
  p_save_snapshot boolean DEFAULT false
)
RETURNS TABLE (
  interaction_id text,
  gen_max integer,
  spans_total bigint,
  spans_active bigint,
  attributions bigint,
  review_items bigint,
  review_gap bigint,
  override_reseeds bigint,
  status text
) AS $$
DECLARE
  v_gen_max integer;
  v_spans_total bigint;
  v_spans_active bigint;
  v_attributions bigint;
  v_review_items bigint;
  v_review_gap bigint;
  v_reseeds bigint;
  v_status text;
BEGIN
  -- Get max generation
  SELECT COALESCE(max(cs.segment_generation), 0) INTO v_gen_max
  FROM conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id;

  -- Get spans total
  SELECT count(*) INTO v_spans_total
  FROM conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id;

  -- Get spans active
  SELECT count(*) INTO v_spans_active
  FROM conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false;

  -- Get attributions on active spans
  SELECT count(*) INTO v_attributions
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id
  WHERE cs.interaction_id = p_interaction_id AND cs.is_superseded = false;

  -- Get review items on active spans
  SELECT count(*) INTO v_review_items
  FROM review_queue rq
  JOIN conversation_spans cs ON cs.id = rq.span_id
  WHERE cs.interaction_id = p_interaction_id 
    AND cs.is_superseded = false 
    AND rq.status = 'pending';

  -- Get review gap (needs_review but not queued)
  SELECT count(*) INTO v_review_gap
  FROM span_attributions sa
  JOIN conversation_spans cs ON cs.id = sa.span_id
  LEFT JOIN review_queue rq ON rq.span_id = sa.span_id AND rq.status = 'pending'
  WHERE cs.interaction_id = p_interaction_id 
    AND cs.is_superseded = false
    AND (sa.needs_review = true OR sa.decision = 'review')
    AND rq.id IS NULL;

  -- Get reseed count
  SELECT count(*) INTO v_reseeds
  FROM override_log ol
  WHERE ol.entity_type = 'reseed' AND ol.interaction_id = p_interaction_id;

  -- Compute status
  v_status := CASE WHEN v_review_gap = 0 THEN 'PASS' ELSE 'FAIL' END;

  -- Optionally save snapshot
  IF p_save_snapshot THEN
    INSERT INTO pipeline_scoreboard_snapshots (
      interaction_id, gen_max, spans_total, spans_active, 
      attributions, review_items, review_gap, override_reseeds, status
    ) VALUES (
      p_interaction_id, v_gen_max, v_spans_total, v_spans_active,
      v_attributions, v_review_items, v_review_gap, v_reseeds, v_status
    );
  END IF;

  -- Return result
  RETURN QUERY SELECT 
    p_interaction_id, v_gen_max, v_spans_total, v_spans_active,
    v_attributions, v_review_items, v_review_gap, v_reseeds, v_status;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION score_interaction(text, boolean) IS
  'Canonical scoreboard function. Returns PASS/FAIL. Use p_save_snapshot=true to persist for regression tracking.';;
