-- ============================================================
-- View: v_review_spans_missing_extraction
-- Directive: dev_review_span_extraction_retarget
-- Applied: 2026-02-15
-- ============================================================
-- Identifies review-decision spans with confidence >= 0.70
-- that have no extracted journal_claims, enabling backfill
-- and ongoing extraction gap monitoring.

DROP VIEW IF EXISTS v_review_spans_missing_extraction;
CREATE VIEW v_review_spans_missing_extraction AS
SELECT
  sa.id AS attribution_id,
  sa.span_id,
  cs.interaction_id,
  cs.span_index,
  sa.project_id AS suggested_project_id,
  sa.applied_project_id,
  sa.confidence,
  sa.decision,
  sa.attribution_source,
  sa.evidence_tier,
  sa.attributed_at
FROM span_attributions sa
JOIN conversation_spans cs ON cs.id = sa.span_id
LEFT JOIN journal_claims jc ON jc.source_span_id = sa.span_id
WHERE sa.decision = 'review'
  AND sa.confidence >= 0.70
  AND jc.id IS NULL;
COMMENT ON VIEW v_review_spans_missing_extraction IS
  'Review spans with confidence >= 0.70 that have no extracted journal_claims. Used for backfill recovery and ongoing extraction gap monitoring.';
