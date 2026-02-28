-- Proof pack for p0_redline_truth_graph_defect_events_and_materialized_context__20260228
-- Acceptance target interaction_id: cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0

with tg as (
  select *
  from public.redline_truth_graph_v1('cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0')
)
select
  interaction_id,
  interaction_uuid,
  project_id,
  defect_type,
  lane_label,
  graph->'nodes'->'calls_raw'->>'status' as calls_raw_status,
  graph->'nodes'->'interactions'->>'status' as interactions_status,
  graph->'nodes'->'conversation_spans'->>'status' as conversation_spans_status,
  graph->'nodes'->'evidence_events'->>'status' as evidence_events_status,
  graph->'nodes'->'span_attributions'->>'status' as span_attributions_status,
  graph->'nodes'->'review_queue_pending'->>'status' as review_queue_pending_status,
  graph->'nodes'->'journal_claims'->>'status' as journal_claims_status,
  graph->'nodes'->'journal_open_loops'->>'status' as journal_open_loops_status
from tg;

with tg as (
  select *
  from public.redline_truth_graph_v1('cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0')
), ins as (
  select public.upsert_redline_defect_event_v1(
    case when tg.defect_type in ('ingestion_missing','projection_gap','missing_evidence','missing_attribution','stale_context','sms_gap','unknown')
         then tg.defect_type else 'unknown' end,
    case when tg.lane_label in ('ingestion','segmentation','attribution','journal','projection','client')
         then tg.lane_label else 'projection' end,
    tg.interaction_id,
    null,
    null,
    null,
    tg.project_id,
    jsonb_build_object('proof_source', 'p0_redline_truth_graph_defect_events_materialized_context_proof_20260228.sql'),
    'open',
    null,
    'data-3:proof'
  ) as defect_event_id
  from tg
)
select
  d.defect_event_id,
  d.defect_type,
  d.owner_lane,
  d.interaction_id,
  d.project_id,
  d.current_status,
  d.first_seen_at_utc,
  d.last_seen_at_utc
from public.redline_defect_events d
where d.interaction_id = 'cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0'
order by d.last_seen_at_utc desc
limit 1;

with upsert_meta as (
  select public.upsert_context_surface_refresh_metadata_v1(
    'mat_project_context',
    null,
    'v1',
    array['v_project_feed']::text[],
    'proof_run_20260228',
    now(),
    jsonb_build_object('proof_source', 'p0_redline_truth_graph_defect_events_materialized_context_proof_20260228.sql')
  ) as context_surface_metadata_id
)
select
  v.context_surface_metadata_id,
  v.surface_name,
  v.context_version,
  v.source_views,
  coalesce(v.pipeline_run_id, '<null>') as pipeline_run_id,
  v.refreshed_at_utc,
  v.pipeline_success_at_utc,
  v.is_stale,
  v.lag_seconds,
  v.staleness_rule
from public.v_context_surface_staleness_v1 v
where v.surface_name = 'mat_project_context'
order by v.updated_at_utc desc
limit 1;
