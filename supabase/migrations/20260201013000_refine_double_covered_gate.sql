-- ============================================================
-- REFINE NO_DOUBLE_COVERED GATE
-- Only flag spans where:
--   1. Attribution has project_id IS NOT NULL (decision made)
--   2. AND there's still an open/pending review
-- Spans with project_id=NULL are "needs review" and expected to have open reviews
-- ============================================================

CREATE OR REPLACE FUNCTION ci_gate_no_double_covered()
RETURNS TABLE (
  gate_name TEXT,
  gate_status TEXT,
  violation_count INT,
  violations JSONB
) AS $$
DECLARE
  v_violations JSONB;
  v_count INT;
BEGIN
  SELECT
    COUNT(*)::INT,
    COALESCE(jsonb_agg(jsonb_build_object(
      'span_id', cs.id,
      'interaction_id', cs.interaction_id,
      'span_index', cs.span_index,
      'attributed_project', sa.project_id,
      'review_status', rq.status
    ) ORDER BY cs.interaction_id, cs.span_index), '[]'::jsonb)
  INTO v_count, v_violations
  FROM conversation_spans cs
  JOIN span_attributions sa ON cs.id = sa.span_id
    AND sa.project_id IS NOT NULL  -- Only flag when decision was actually made
  JOIN review_queue rq ON cs.id = rq.span_id
    AND rq.status IN ('open', 'pending')
  WHERE cs.is_superseded = false
  LIMIT 20;

  RETURN QUERY SELECT
    'no_double_covered'::TEXT,
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    v_count,
    v_violations;
END;
$$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION ci_gate_no_double_covered IS 'CI Gate 4: Span with resolved attribution (project_id NOT NULL) cannot also have open review';
