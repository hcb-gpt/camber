-- View to surface review coverage gaps
-- Per STRAT TURN:67: spans needing review but not queued

CREATE OR REPLACE VIEW v_review_coverage_gaps AS
SELECT 
  cs.interaction_id,
  cs.id as span_id,
  cs.span_index,
  sa.decision,
  sa.needs_review,
  sa.reasoning,
  sa.attributed_at,
  LEFT(cs.transcript_segment, 100) as snippet
FROM conversation_spans cs
JOIN span_attributions sa ON sa.span_id = cs.id
LEFT JOIN review_queue rq ON rq.span_id = cs.id AND rq.status = 'pending'
WHERE cs.is_superseded = false
  AND (sa.needs_review = true OR sa.decision = 'review')
  AND rq.id IS NULL;

COMMENT ON VIEW v_review_coverage_gaps IS
  'Spans needing review but not in review_queue. Gap count should be 0 after fix.';;
