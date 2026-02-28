-- Fix no_double_covered gate logic per DATA-1 analysis
--
-- ISSUE: Gate was flagging 79 legitimate spans where:
--   - ai-router decided decision='review'
--   - Created span_attribution with needs_review=true
--   - Created review_queue item with status='pending'
--   Both existing together IS THE EXPECTED STATE for review spans.
--
-- FIX: Only flag as "double covered" when:
--   - Attribution is RESOLVED (needs_review=false)
--   - But review_queue is still pending
--
-- This catches the actual bug (stale review items not cleaned up after resolution)
-- without flagging legitimate review-pending spans.

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
      'needs_review', sa.needs_review,
      'review_status', rq.status
    ) ORDER BY cs.interaction_id, cs.span_index), '[]'::jsonb)
  INTO v_count, v_violations
  FROM conversation_spans cs
  JOIN span_attributions sa ON cs.id = sa.span_id
    AND sa.needs_review = false  -- Only flag when attribution is RESOLVED
  JOIN review_queue rq ON cs.id = rq.span_id
    AND rq.status = 'pending'    -- And review is still open
  WHERE cs.is_superseded = false
  LIMIT 20;

  RETURN QUERY SELECT
    'no_double_covered'::TEXT,
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    v_count,
    v_violations;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
COMMENT ON FUNCTION ci_gate_no_double_covered IS 'CI Gate 4: Span with RESOLVED attribution (needs_review=false) cannot also have pending review';
