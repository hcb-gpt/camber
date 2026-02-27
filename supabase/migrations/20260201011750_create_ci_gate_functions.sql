-- ============================================================
-- CI GATE FUNCTIONS
-- Big Rock 1: Hard-fail invariant checks for CI
-- Source: DATA-A Advisory Big Rocks Enhancement Pack
-- ============================================================

-- ============================================================
-- CI GATE 1: MULTI_SPAN_REQUIRED
-- Long transcripts (>2000 chars) must produce >1 active span
-- ============================================================
CREATE OR REPLACE FUNCTION ci_gate_multi_span_required()
RETURNS TABLE (
  gate_name TEXT,
  status TEXT,
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
      'interaction_id', sub.interaction_id,
      'transcript_chars', sub.transcript_chars,
      'span_count', sub.span_count
    ) ORDER BY sub.transcript_chars DESC), '[]'::jsonb)
  INTO v_count, v_violations
  FROM (
    SELECT
      cs.interaction_id,
      LENGTH(cr.transcript) as transcript_chars,
      COUNT(cs.id) as span_count
    FROM conversation_spans cs
    JOIN calls_raw cr ON cr.interaction_id = cs.interaction_id
    WHERE cs.is_superseded = false
      AND LENGTH(COALESCE(cr.transcript, '')) > 2000
    GROUP BY cs.interaction_id, cr.transcript
    HAVING COUNT(cs.id) <= 1
    LIMIT 20
  ) sub;

  RETURN QUERY SELECT
    'multi_span_required'::TEXT,
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    v_count,
    v_violations;
END;
$$ LANGUAGE plpgsql STABLE;
-- ============================================================
-- CI GATE 2: NO_GAP
-- Adjacent spans must have no character gaps (contiguous)
-- ============================================================
CREATE OR REPLACE FUNCTION ci_gate_no_gap()
RETURNS TABLE (
  gate_name TEXT,
  status TEXT,
  violation_count INT,
  violations JSONB
) AS $$
DECLARE
  v_violations JSONB;
  v_count INT;
BEGIN
  WITH span_gaps AS (
    SELECT
      cs.interaction_id,
      cs.span_index,
      cs.char_start,
      cs.char_end,
      LAG(cs.char_end) OVER (
        PARTITION BY cs.interaction_id
        ORDER BY cs.span_index
      ) as prev_end
    FROM conversation_spans cs
    WHERE cs.is_superseded = false
  )
  SELECT
    COUNT(*)::INT,
    COALESCE(jsonb_agg(jsonb_build_object(
      'interaction_id', interaction_id,
      'span_index', span_index,
      'char_start', char_start,
      'prev_end', prev_end,
      'gap', char_start - prev_end
    ) ORDER BY interaction_id, span_index), '[]'::jsonb)
  INTO v_count, v_violations
  FROM span_gaps
  WHERE prev_end IS NOT NULL
    AND char_start != prev_end
  LIMIT 20;

  RETURN QUERY SELECT
    'no_gap'::TEXT,
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    v_count,
    v_violations;
END;
$$ LANGUAGE plpgsql STABLE;
-- ============================================================
-- CI GATE 3: NO_UNCOVERED
-- Every active span must have attribution OR open/pending review
-- "Covered" = attribution exists OR review_queue status in (open, pending)
-- ============================================================
CREATE OR REPLACE FUNCTION ci_gate_no_uncovered()
RETURNS TABLE (
  gate_name TEXT,
  status TEXT,
  violation_count INT,
  violations JSONB
) AS $$
DECLARE
  v_violations JSONB;
  v_count INT;
BEGIN
  WITH active_spans AS (
    SELECT cs.id as span_id, cs.interaction_id, cs.span_index
    FROM conversation_spans cs
    WHERE cs.is_superseded = false
  ),
  covered_by_attribution AS (
    SELECT DISTINCT span_id
    FROM span_attributions
  ),
  covered_by_review AS (
    SELECT DISTINCT span_id
    FROM review_queue
    WHERE status IN ('open', 'pending')
  )
  SELECT
    COUNT(*)::INT,
    COALESCE(jsonb_agg(jsonb_build_object(
      'span_id', a.span_id,
      'interaction_id', a.interaction_id,
      'span_index', a.span_index
    ) ORDER BY a.interaction_id, a.span_index), '[]'::jsonb)
  INTO v_count, v_violations
  FROM active_spans a
  LEFT JOIN covered_by_attribution ca ON a.span_id = ca.span_id
  LEFT JOIN covered_by_review cr ON a.span_id = cr.span_id
  WHERE ca.span_id IS NULL AND cr.span_id IS NULL
  LIMIT 20;

  RETURN QUERY SELECT
    'no_uncovered'::TEXT,
    CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
    v_count,
    v_violations;
END;
$$ LANGUAGE plpgsql STABLE;
-- ============================================================
-- CI GATE 4: NO_DOUBLE_COVERED
-- Span cannot have BOTH attribution AND open/pending review
-- ============================================================
CREATE OR REPLACE FUNCTION ci_gate_no_double_covered()
RETURNS TABLE (
  gate_name TEXT,
  status TEXT,
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
-- ============================================================
-- MASTER CI RUNNER
-- Run all gates, return aggregate result
-- ============================================================
CREATE OR REPLACE FUNCTION ci_run_all_gates()
RETURNS TABLE (
  gate_name TEXT,
  status TEXT,
  violation_count INT,
  violations JSONB
) AS $$
BEGIN
  RETURN QUERY SELECT * FROM ci_gate_multi_span_required();
  RETURN QUERY SELECT * FROM ci_gate_no_gap();
  RETURN QUERY SELECT * FROM ci_gate_no_uncovered();
  RETURN QUERY SELECT * FROM ci_gate_no_double_covered();
END;
$$ LANGUAGE plpgsql STABLE;
-- Usage in CI:
-- SELECT * FROM ci_run_all_gates();
-- CI fails if ANY row has status = 'FAIL'

COMMENT ON FUNCTION ci_gate_multi_span_required IS 'CI Gate 1: Long transcripts (>2000 chars) must have >1 span';
COMMENT ON FUNCTION ci_gate_no_gap IS 'CI Gate 2: Adjacent spans must be contiguous (no char gaps)';
COMMENT ON FUNCTION ci_gate_no_uncovered IS 'CI Gate 3: Every active span must have attribution OR open review';
COMMENT ON FUNCTION ci_gate_no_double_covered IS 'CI Gate 4: Span cannot have both attribution AND open review';
COMMENT ON FUNCTION ci_run_all_gates IS 'Master CI runner - executes all 4 invariant gates';
