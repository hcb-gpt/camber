CREATE OR REPLACE FUNCTION public.redline_truth_graph_v1(p_interaction_id text)
 RETURNS TABLE(interaction_id text, interaction_uuid uuid, project_id uuid, thread_id text, lane_label text, primary_defect_type text, all_failing_lanes text[], node_statuses jsonb, calls_raw_ids uuid[], interaction_ids text[], span_ids uuid[], evidence_event_ids uuid[], span_attribution_ids uuid[], review_queue_ids uuid[], journal_claim_ids uuid[], journal_open_loop_ids uuid[], redline_thread_rows bigint, context_staleness_status text, context_refreshed_at_utc timestamp with time zone, latest_pipeline_activity_at_utc timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH i AS (
  SELECT i.id, i.interaction_id, i.project_id, i.thread_key,
         i.event_at_utc, i.ingested_at_utc
  FROM public.interactions i
  WHERE i.interaction_id = p_interaction_id
), i_latest AS (
  SELECT i.id, i.interaction_id, i.project_id, i.thread_key
  FROM i
  ORDER BY i.ingested_at_utc DESC NULLS LAST, i.event_at_utc DESC NULLS LAST
  LIMIT 1
), calls AS (
  SELECT count(*)::int AS cnt,
    coalesce(array_agg(cr.id ORDER BY cr.event_at_utc DESC), array[]::uuid[]) AS ids
  FROM public.calls_raw cr
  WHERE cr.interaction_id = p_interaction_id
    AND coalesce(cr.is_shadow, false) = false
), spans AS (
  SELECT count(*)::int AS cnt,
    coalesce(array_agg(cs.id ORDER BY cs.span_index), array[]::uuid[]) AS ids
  FROM public.conversation_spans cs
  WHERE cs.interaction_id = p_interaction_id
    AND coalesce(cs.is_superseded, false) = false
), evidence AS (
  SELECT count(*)::int AS cnt,
    coalesce(array_agg(ev.evidence_event_id ORDER BY ev.created_at DESC), array[]::uuid[]) AS ids
  FROM public.evidence_events ev
  WHERE ev.source_id = p_interaction_id
     OR coalesce(ev.metadata->>'interaction_id', '') = p_interaction_id
     OR coalesce(ev.metadata->>'call_id', '') = p_interaction_id
), attrs AS (
  SELECT count(*)::int AS cnt,
    count(*) FILTER (WHERE coalesce(sa.needs_review, false) IS true)::int AS needs_review_cnt,
    coalesce(array_agg(sa.id ORDER BY sa.attributed_at DESC), array[]::uuid[]) AS ids
  FROM public.span_attributions sa
  JOIN public.conversation_spans cs ON cs.id = sa.span_id
  WHERE cs.interaction_id = p_interaction_id
    AND coalesce(cs.is_superseded, false) = false
), rq AS (
  SELECT count(*)::int AS cnt,
    count(*) FILTER (WHERE rq.status = 'pending')::int AS pending_cnt,
    coalesce(array_agg(rq.id ORDER BY rq.created_at DESC), array[]::uuid[]) AS ids
  FROM public.review_queue rq
  WHERE rq.interaction_id = p_interaction_id
     OR rq.span_id IN (
        SELECT cs.id FROM public.conversation_spans cs
        WHERE cs.interaction_id = p_interaction_id
          AND coalesce(cs.is_superseded, false) = false
     )
), jc AS (
  SELECT count(*)::int AS cnt,
    count(*) FILTER (WHERE coalesce(jc.active, false) IS true)::int AS active_cnt,
    coalesce(array_agg(jc.id ORDER BY jc.created_at DESC), array[]::uuid[]) AS ids
  FROM public.journal_claims jc
  WHERE jc.call_id = p_interaction_id
), jol AS (
  SELECT count(*)::int AS cnt,
    count(*) FILTER (WHERE jol.status = 'open')::int AS open_cnt,
    coalesce(array_agg(jol.id ORDER BY jol.created_at DESC), array[]::uuid[]) AS ids
  FROM public.journal_open_loops jol
  WHERE jol.call_id = p_interaction_id
), rt AS (
  SELECT count(*)::int AS cnt
  FROM public.redline_thread rt
  WHERE rt.interaction_id IN (SELECT i2.id FROM i i2)
), meta AS (
  SELECT
    coalesce(vpcmh.staleness_status, 'unknown') AS staleness_status,
    vpcmh.refreshed_at_utc,
    vpcmh.latest_pipeline_activity_at_utc
  FROM public.v_project_context_materialization_health_v1 vpcmh
),
-- Collect ALL failing lanes (not just first)
lane_checks AS (
  SELECT unnest(array_remove(ARRAY[
    CASE WHEN calls.cnt = 0 OR (SELECT count(*) FROM i) = 0 THEN 'ingestion' END,
    CASE WHEN spans.cnt = 0 THEN 'segmentation' END,
    CASE WHEN evidence.cnt = 0 THEN 'evidence' END,
    CASE WHEN attrs.cnt = 0 THEN 'attribution' END,
    CASE WHEN rt.cnt = 0 THEN 'projection' END,
    CASE WHEN meta.staleness_status = 'stale' THEN 'context_stale' END,
    CASE WHEN rq.pending_cnt > 0 THEN 'review_pending' END,
    CASE WHEN jc.active_cnt = 0 AND jol.open_cnt = 0 THEN 'journal' END
  ], NULL)) AS failing_lane
  FROM calls, spans, evidence, attrs, rq, jc, jol, rt, meta
)
SELECT
  p_interaction_id AS interaction_id,
  il.id AS interaction_uuid,
  il.project_id,
  il.thread_key AS thread_id,
  -- Primary lane (first failure, backward compat)
  CASE
    WHEN calls.cnt = 0 OR (SELECT count(*) FROM i) = 0 THEN 'ingestion'
    WHEN spans.cnt = 0 THEN 'segmentation'
    WHEN evidence.cnt = 0 THEN 'evidence'
    WHEN attrs.cnt = 0 THEN 'attribution'
    WHEN rt.cnt = 0 THEN 'projection'
    WHEN meta.staleness_status = 'stale' THEN 'projection'
    WHEN rq.pending_cnt > 0 THEN 'client'
    WHEN jc.active_cnt = 0 AND jol.open_cnt = 0 THEN 'journal'
    ELSE 'healthy'
  END AS lane_label,
  CASE
    WHEN calls.cnt = 0 OR (SELECT count(*) FROM i) = 0 THEN 'ingestion_missing'
    WHEN spans.cnt = 0 THEN 'missing_evidence'
    WHEN evidence.cnt = 0 THEN 'missing_evidence'
    WHEN attrs.cnt = 0 THEN 'missing_attribution'
    WHEN rt.cnt = 0 THEN 'projection_gap'
    WHEN meta.staleness_status = 'stale' THEN 'stale_context'
    WHEN rq.pending_cnt > 0 THEN 'missing_attribution'
    WHEN jc.active_cnt = 0 AND jol.open_cnt = 0 THEN 'journal_gap'
    ELSE NULL
  END AS primary_defect_type,
  -- NEW: all failing lanes as array
  coalesce((SELECT array_agg(lc.failing_lane) FROM lane_checks lc), array[]::text[]) AS all_failing_lanes,
  jsonb_build_object(
    'calls_raw', jsonb_build_object('present', calls.cnt > 0, 'count', calls.cnt, 'ids', to_jsonb(calls.ids)),
    'interactions', jsonb_build_object(
      'present', (SELECT count(*) FROM i) > 0,
      'count', (SELECT count(*) FROM i),
      'ids', to_jsonb(coalesce((SELECT array_agg(i2.interaction_id ORDER BY i2.ingested_at_utc DESC) FROM i i2), array[]::text[]))
    ),
    'conversation_spans', jsonb_build_object('present', spans.cnt > 0, 'count', spans.cnt, 'ids', to_jsonb(spans.ids)),
    'evidence_events', jsonb_build_object('present', evidence.cnt > 0, 'count', evidence.cnt, 'ids', to_jsonb(evidence.ids)),
    'span_attributions', jsonb_build_object('present', attrs.cnt > 0, 'count', attrs.cnt, 'needs_review_count', attrs.needs_review_cnt, 'ids', to_jsonb(attrs.ids)),
    'review_queue', jsonb_build_object('present', rq.cnt > 0, 'count', rq.cnt, 'pending_count', rq.pending_cnt, 'ids', to_jsonb(rq.ids)),
    'journal_claims', jsonb_build_object('present', jc.cnt > 0, 'count', jc.cnt, 'active_count', jc.active_cnt, 'ids', to_jsonb(jc.ids)),
    'journal_open_loops', jsonb_build_object('present', jol.cnt > 0, 'count', jol.cnt, 'open_count', jol.open_cnt, 'ids', to_jsonb(jol.ids)),
    'redline_thread', jsonb_build_object('present', rt.cnt > 0, 'count', rt.cnt),
    'context_materialization', jsonb_build_object(
      'staleness_status', meta.staleness_status,
      'refreshed_at_utc', meta.refreshed_at_utc,
      'latest_pipeline_activity_at_utc', meta.latest_pipeline_activity_at_utc
    )
  ) AS node_statuses,
  calls.ids AS calls_raw_ids,
  coalesce((SELECT array_agg(i2.interaction_id ORDER BY i2.ingested_at_utc DESC) FROM i i2), array[]::text[]) AS interaction_ids,
  spans.ids AS span_ids,
  evidence.ids AS evidence_event_ids,
  attrs.ids AS span_attribution_ids,
  rq.ids AS review_queue_ids,
  jc.ids AS journal_claim_ids,
  jol.ids AS journal_open_loop_ids,
  rt.cnt::bigint AS redline_thread_rows,
  meta.staleness_status AS context_staleness_status,
  meta.refreshed_at_utc AS context_refreshed_at_utc,
  meta.latest_pipeline_activity_at_utc
FROM calls
CROSS JOIN spans
CROSS JOIN evidence
CROSS JOIN attrs
CROSS JOIN rq
CROSS JOIN jc
CROSS JOIN jol
CROSS JOIN rt
CROSS JOIN meta
LEFT JOIN i_latest il ON true;
$function$