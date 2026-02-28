-- v2.10.0: Human truth attribution training data views
-- Spec: SPEC_human_truth_attribution_export_v1
-- Thread: redline_attribution
--
-- Creates two views:
-- 1. v_human_truth_attributions — per-span training records for human-locked attributions
-- 2. v_human_truth_daily_metrics — daily flywheel health dashboard
--
-- Training eligibility: attribution_lock='human', active span (not superseded),
-- non-synthetic model_id. Includes 5% hash-based holdout for eval (mod 20 = 0).
--
-- Label taxonomy:
--   PROJECT     — applied_project_id IS NOT NULL (positive training example)
--   UNKNOWN     — resolution_action in ('unknown','no_project') (negative/uncertain)
--   NEEDS_SPLIT — resolution_action = 'needs_split' (exclude from training, keep for analysis)

-- 1) Training data view
CREATE OR REPLACE VIEW public.v_human_truth_attributions AS
SELECT
  -- Core identifiers
  sa.id                       AS attribution_id,
  sa.span_id,
  cs.interaction_id,
  i.id                        AS interaction_uuid,
  cs.span_index,

  -- Timestamps
  i.event_at_utc,
  sa.applied_at_utc           AS resolved_at_attribution,
  rq.resolved_at              AS resolved_at_review,

  -- Contact
  i.contact_id,
  i.contact_name,
  COALESCE(c.phone, i.contact_phone) AS contact_phone,

  -- Model input (training feature)
  cs.transcript_segment,

  -- Label (training target)
  sa.applied_project_id       AS chosen_project_id,
  p.name                      AS chosen_project_name,
  CASE
    WHEN sa.applied_project_id IS NOT NULL THEN 'PROJECT'
    WHEN rq.resolution_action IN ('unknown','no_project') THEN 'UNKNOWN'
    WHEN rq.resolution_action = 'needs_split' THEN 'NEEDS_SPLIT'
    ELSE 'UNKNOWN'
  END                         AS label_type,

  -- Provenance: who resolved
  rq.id                       AS review_queue_id,
  rq.resolved_by              AS reviewer_id,
  rq.resolution_action,
  rq.resolution_notes,

  -- Provenance: override audit
  ol.id                       AS override_log_id,
  ol.idempotency_key,
  ol.reason                   AS override_reason,

  -- AI model context (what the model predicted before human correction)
  sa.project_id               AS ai_suggested_project_id,
  sa.decision                 AS ai_decision,
  sa.confidence               AS ai_confidence,
  sa.model_id,
  sa.prompt_version,
  sa.reasoning,
  sa.anchors,
  sa.candidates_snapshot,
  sa.top_candidates,

  -- Correction signal
  CASE
    WHEN sa.applied_project_id IS NOT NULL
     AND sa.project_id IS NOT NULL
     AND sa.applied_project_id != sa.project_id THEN true
    ELSE false
  END                         AS is_correction,

  -- Holdout: hash-based 5% split on span_id for eval
  (('x' || left(md5(sa.span_id::text), 8))::bit(32)::int % 20 = 0) AS is_holdout,

  -- Metadata
  sa.attribution_lock,
  sa.attribution_source,
  i.channel

FROM span_attributions sa
JOIN conversation_spans cs     ON cs.id = sa.span_id
JOIN interactions i             ON i.interaction_id = cs.interaction_id
LEFT JOIN contacts c            ON c.id = i.contact_id
LEFT JOIN projects p            ON p.id = sa.applied_project_id
LEFT JOIN review_queue rq       ON rq.span_id = sa.span_id
LEFT JOIN override_log ol       ON ol.review_queue_id = rq.id
                               AND ol.idempotency_key LIKE 'resolve:%'

WHERE sa.attribution_lock = 'human'
  AND cs.is_superseded = false
  -- Exclude synthetic/backfill model IDs from training
  AND COALESCE(sa.model_id, '') NOT IN ('audit_hard_drop_backfill', 'data4.manual.test_fixture');


-- 2) Daily metrics view
CREATE OR REPLACE VIEW public.v_human_truth_daily_metrics AS
WITH daily AS (
  SELECT
    date_trunc('day', resolved_at_attribution)::date AS day,
    count(*)                                          AS labeled_count,
    count(CASE WHEN label_type = 'UNKNOWN' THEN 1 END) AS unknown_count,
    count(CASE WHEN is_correction THEN 1 END)         AS correction_count,
    count(CASE WHEN is_holdout THEN 1 END)            AS holdout_count,
    count(DISTINCT chosen_project_id)                  AS projects_seen,
    count(DISTINCT contact_id)                         AS contacts_seen,
    avg(ai_confidence)                                 AS avg_ai_confidence,
    -- Candidate hit@1: did the AI's top suggestion match the human choice?
    count(CASE
      WHEN chosen_project_id IS NOT NULL
       AND ai_suggested_project_id = chosen_project_id
      THEN 1
    END)                                               AS hit_at_1,
    -- Time to decision: ingestion -> resolution
    avg(EXTRACT(EPOCH FROM (resolved_at_attribution - event_at_utc)) / 3600) AS avg_hours_to_decision
  FROM v_human_truth_attributions
  WHERE resolved_at_attribution IS NOT NULL
  GROUP BY 1
)
SELECT
  day,
  labeled_count,
  unknown_count,
  round(100.0 * unknown_count / NULLIF(labeled_count, 0), 1) AS pct_unknown,
  correction_count,
  round(100.0 * correction_count / NULLIF(labeled_count, 0), 1) AS correction_rate,
  holdout_count,
  projects_seen,
  contacts_seen,
  round(avg_ai_confidence::numeric, 3)  AS avg_ai_confidence,
  hit_at_1,
  round(100.0 * hit_at_1 / NULLIF(labeled_count, 0), 1) AS hit_at_1_rate,
  round(avg_hours_to_decision::numeric, 1) AS avg_hours_to_decision
FROM daily
ORDER BY day DESC;
