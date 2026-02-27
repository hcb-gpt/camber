-- hard_drop_sla_backfill_v1
--
-- Purpose:
-- - Backfill missing span-level pending review_queue rows for spans that breach the
--   hard-drop SLA (age_hours >= 24) but have no pending review_queue row.
--
-- Safety:
-- - Idempotent: inserts only spans with NO review_queue row for span_id.
-- - Does not mask SLA: sets review_queue.created_at = pending_since_utc (not now()).
-- - Keeps module constrained: module='attribution'.
--
-- Rollback:
-- - Delete pending rows inserted by this backfill:
--   delete from public.review_queue
--   where status = 'pending'
--     and context_payload->>'source' = 'hard_drop_sla_backfill_v1';

BEGIN;

WITH active_spans AS (
  SELECT
    cs.id AS span_id,
    cs.interaction_id,
    COALESCE(cs.created_at, NOW()) AS span_created_at_utc
  FROM public.conversation_spans cs
  WHERE COALESCE(cs.is_superseded, false) = false
    AND cs.interaction_id NOT LIKE 'cll_SHADOW%'
    AND cs.interaction_id NOT LIKE 'cll_RACECHK%'
    AND cs.interaction_id NOT LIKE 'cll_DEV%'
    AND cs.interaction_id NOT LIKE 'cll_CHAIN%'
),
latest_attr AS (
  SELECT DISTINCT ON (sa.span_id)
    sa.span_id,
    COALESCE(sa.applied_at_utc, sa.attributed_at, NOW()) AS attributed_at_utc,
    TO_JSONB(sa) AS attr_json
  FROM public.span_attributions sa
  ORDER BY
    sa.span_id,
    COALESCE(sa.applied_at_utc, sa.attributed_at, NOW()) DESC,
    sa.id DESC
),
latest_pending_review AS (
  SELECT DISTINCT ON (rq.span_id)
    rq.span_id,
    rq.created_at AS review_created_at_utc
  FROM public.review_queue rq
  WHERE rq.status = 'pending'
  ORDER BY rq.span_id, rq.created_at DESC, rq.id DESC
),
reviewed_by_proxy AS (
  SELECT DISTINCT avf.span_id
  FROM public.attribution_validation_feedback avf
  WHERE avf.source = 'llm_proxy_review'
),
pending_spans AS (
  SELECT
    s.span_id,
    s.interaction_id,
    la.attributed_at_utc,
    la.attr_json,
    rq.review_created_at_utc,
    COALESCE(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, NOW()) AS pending_since_utc,
    EXTRACT(EPOCH FROM (NOW() - COALESCE(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, NOW()))) / 3600.0 AS age_hours
  FROM active_spans s
  LEFT JOIN latest_attr la ON la.span_id = s.span_id
  LEFT JOIN latest_pending_review rq ON rq.span_id = s.span_id
  LEFT JOIN reviewed_by_proxy rbp ON rbp.span_id = s.span_id
  WHERE (
      la.span_id IS NULL
      OR NULLIF(la.attr_json->>'decision', '') IS NULL
      OR la.attr_json->>'decision' = 'review'
      OR COALESCE((la.attr_json->>'needs_review')::boolean, false) = true
    )
    AND rbp.span_id IS NULL
),
breach_missing_pending AS (
  SELECT
    p.*,
    CASE
      WHEN p.attr_json IS NULL THEN 'missing_span_attribution'
      WHEN p.attr_json->>'decision' = 'review' THEN 'decision_review'
      WHEN COALESCE((p.attr_json->>'needs_review')::boolean, false) = true THEN 'needs_review_true'
      ELSE 'other'
    END AS breach_reason
  FROM pending_spans p
  WHERE p.age_hours >= 24
    AND p.review_created_at_utc IS NULL
),
inserted AS (
  INSERT INTO public.review_queue (
    span_id,
    interaction_id,
    reasons,
    context_payload,
    status,
    created_at,
    module
  )
  SELECT
    b.span_id,
    b.interaction_id,
    ARRAY['hard_drop_sla_breach', b.breach_reason]::text[] AS reasons,
    JSONB_BUILD_OBJECT(
      'source', 'hard_drop_sla_backfill_v1',
      'pending_since_utc', b.pending_since_utc,
      'age_hours_at_backfill', ROUND(b.age_hours::numeric, 2),
      'breach_reason', b.breach_reason,
      'attributed_by', COALESCE(NULLIF(b.attr_json->>'attributed_by', ''), NULL)
    ) AS context_payload,
    'pending' AS status,
    b.pending_since_utc AS created_at,
    'attribution' AS module
  FROM breach_missing_pending b
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.review_queue rq2
    WHERE rq2.span_id = b.span_id
  )
  RETURNING span_id
)
SELECT
  COUNT(*) AS rows_inserted,
  (SELECT ARRAY_AGG(span_id::text)
   FROM (SELECT span_id FROM inserted ORDER BY span_id LIMIT 3) s
  ) AS sample_span_ids
FROM inserted;

COMMIT;

