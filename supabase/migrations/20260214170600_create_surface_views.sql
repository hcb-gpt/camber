-- Surface views from STRAT-2 blackboard designs:
-- - public.v_project_feed
-- - public.v_needs_triage

DROP VIEW IF EXISTS public.v_project_feed;
CREATE VIEW public.v_project_feed AS
SELECT
  p.id AS project_id,
  p.name AS project_name,
  p.status AS project_status,
  p.phase,
  p.client_name,
  (SELECT count(*) FROM interactions i WHERE i.project_id = p.id) AS total_interactions,
  (SELECT max(i.event_at_utc) FROM interactions i WHERE i.project_id = p.id) AS last_interaction_at,
  (SELECT count(*) FROM interactions i
   WHERE i.project_id = p.id
   AND i.event_at_utc >= now() - interval '7 days') AS interactions_7d,
  (SELECT count(*) FROM journal_claims jc
   WHERE jc.project_id = p.id
   AND jc.active = true) AS active_journal_claims,
  (SELECT count(*) FROM journal_open_loops ol
   WHERE ol.project_id = p.id
   AND ol.status = 'open') AS open_loops,
  (SELECT count(*) FROM belief_claims bc
   WHERE bc.project_id = p.id) AS promoted_claims,
  (SELECT max(bc.event_at_utc) FROM belief_claims bc
   WHERE bc.project_id = p.id) AS last_promoted_at,
  (SELECT count(*) FROM striking_signals ss
   JOIN conversation_spans cs ON ss.span_id = cs.id
   JOIN span_attributions sa ON sa.span_id = cs.id
   WHERE sa.applied_project_id = p.id) AS striking_signal_count,
  (SELECT max(ss.created_at) FROM striking_signals ss
   JOIN conversation_spans cs ON ss.span_id = cs.id
   JOIN span_attributions sa ON sa.span_id = cs.id
   WHERE sa.applied_project_id = p.id) AS last_striking_at,
  (SELECT count(*) FROM span_attributions sa
   JOIN conversation_spans cs ON sa.span_id = cs.id
   WHERE cs.interaction_id IN (
     SELECT i2.interaction_id FROM interactions i2
     WHERE i2.project_id = p.id)
   AND sa.needs_review = true) AS pending_reviews,
  CASE
    WHEN (SELECT count(*) FROM journal_open_loops ol2
          WHERE ol2.project_id = p.id AND ol2.status = 'open') >= 5
      THEN 'high_open_loops'
    WHEN (SELECT count(*) FROM striking_signals ss2
          JOIN conversation_spans cs2 ON ss2.span_id = cs2.id
          JOIN span_attributions sa2 ON sa2.span_id = cs2.id
          WHERE sa2.applied_project_id = p.id
          AND ss2.created_at >= now() - interval '7 days') >= 3
      THEN 'elevated_striking'
    WHEN (SELECT max(i3.event_at_utc) FROM interactions i3
          WHERE i3.project_id = p.id) < now() - interval '14 days'
      THEN 'stale_project'
    ELSE 'normal'
  END AS risk_flag
FROM projects p
ORDER BY last_interaction_at DESC NULLS LAST;
DROP VIEW IF EXISTS public.v_needs_triage;
CREATE VIEW public.v_needs_triage AS
WITH latest_sa AS (
  SELECT DISTINCT ON (span_id)
    span_id,
    project_id,
    applied_project_id,
    confidence,
    decision,
    attributed_at,
    id
  FROM span_attributions
  ORDER BY span_id, attributed_at DESC NULLS LAST, id DESC
)
SELECT
  rq.id AS triage_id,
  'attribution' AS triage_type,
  rq.interaction_id,
  rq.span_id,
  rq.status,
  rq.reasons[1] AS primary_reason,
  rq.reason_codes AS reason_codes,
  rq.module,
  sa.project_id AS ai_project_id,
  p_ai.name AS ai_project_name,
  sa.applied_project_id,
  p_app.name AS applied_project_name,
  sa.confidence AS ai_confidence,
  sa.decision,
  rq.created_at,
  rq.resolved_at,
  rq.resolved_by,
  rq.resolution_action,
  rq.hit_count,
  COALESCE(rq.hit_count, 1) *
    CASE WHEN sa.confidence < 0.5 THEN 3
         WHEN sa.confidence < 0.7 THEN 2
         ELSE 1 END *
    CASE WHEN rq.created_at < now() - interval '7 days' THEN 2
         ELSE 1 END
    AS urgency_score
FROM review_queue rq
LEFT JOIN latest_sa sa ON sa.span_id = rq.span_id
LEFT JOIN projects p_ai ON p_ai.id = sa.project_id
LEFT JOIN projects p_app ON p_app.id = sa.applied_project_id
WHERE rq.status != 'resolved'
UNION ALL
SELECT
  jrq.id AS triage_id,
  'journal_' || jrq.item_type AS triage_type,
  jrq.call_id AS interaction_id,
  NULL::uuid AS span_id,
  jrq.status,
  jrq.reason AS primary_reason,
  ARRAY[jrq.reason] AS reason_codes,
  'journal' AS module,
  jrq.project_id AS ai_project_id,
  p_j.name AS ai_project_name,
  NULL::uuid AS applied_project_id,
  NULL::text AS applied_project_name,
  NULL::numeric AS ai_confidence,
  NULL::text AS decision,
  jrq.created_at,
  jrq.reviewed_at AS resolved_at,
  jrq.reviewed_by AS resolved_by,
  NULL::text AS resolution_action,
  1 AS hit_count,
  CASE WHEN jrq.item_type = 'conflict' THEN 5
       WHEN jrq.item_type = 'open_loop' THEN 3
       ELSE 1 END *
    CASE WHEN jrq.created_at < now() - interval '7 days' THEN 2
         ELSE 1 END
    AS urgency_score
FROM journal_review_queue jrq
LEFT JOIN projects p_j ON p_j.id = jrq.project_id
WHERE jrq.status != 'resolved';
