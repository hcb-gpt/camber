-- Fix: Use call_id as primary claim→interaction join so ALL claims are visible for grading
-- Span transcript is LEFT JOINed for context (only active spans shown)
-- This surfaces 663 claims for Zack vs 147 with the span-only path

CREATE OR REPLACE VIEW redline_contact_thread AS
SELECT
  i.id AS interaction_id,
  i.event_at_utc,
  i.event_at_local,
  i.channel AS interaction_type,
  cr.direction,
  i.contact_id,
  i.contact_name,
  i.contact_phone,
  NULL::integer AS duration_seconds,
  i.human_summary AS summary,
  cs.id AS span_id,
  cs.span_index,
  cs.transcript_segment,
  jc.speaker_label,
  jc.speaker_contact_id,
  jc.id AS claim_id,
  jc.claim_type,
  jc.claim_text,
  jc.span_text,
  jc.claim_confirmation_state AS confirmation_state,
  cg.id AS grade_id,
  cg.grade,
  cg.correction_text,
  cg.graded_by,
  cg.graded_at
FROM interactions i
LEFT JOIN calls_raw cr
  ON cr.interaction_id = i.interaction_id
LEFT JOIN journal_claims jc
  ON jc.call_id = i.interaction_id
LEFT JOIN conversation_spans cs
  ON cs.id = jc.source_span_id
  AND cs.is_superseded = false
LEFT JOIN claim_grades cg
  ON cg.claim_id = jc.id
WHERE i.contact_id IS NOT NULL
ORDER BY i.event_at_utc DESC, cs.span_index ASC;

COMMENT ON VIEW redline_contact_thread IS 'Redline MVP: chronological thread per contact. Claims join via call_id (complete path). Span transcript LEFT JOINed for context (active spans only). Filter by contact_id.';;
