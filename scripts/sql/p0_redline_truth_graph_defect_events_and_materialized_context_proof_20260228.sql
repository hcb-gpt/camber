-- Proof pack: redline truth graph + defect events + materialized context metadata
-- Receipt: p0_redline_truth_graph_defect_events_and_materialized_context__20260228
-- Usage:
--   /usr/local/opt/libpq/bin/psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/p0_redline_truth_graph_defect_events_and_materialized_context_proof_20260228.sql

\set iid 'cll_06E9MVG4K9W9Z8B9VZ5BR4PBN0'

\echo 'Q1) Truth graph output for required interaction_id (statuses + lane label)'
select
  tg.interaction_id,
  tg.interaction_uuid,
  tg.project_id,
  tg.thread_id,
  tg.lane_label,
  tg.primary_defect_type,
  tg.redline_thread_rows,
  tg.context_staleness_status,
  tg.context_refreshed_at_utc,
  tg.latest_pipeline_activity_at_utc,
  tg.calls_raw_ids,
  tg.interaction_ids,
  tg.span_ids,
  tg.evidence_event_ids,
  tg.span_attribution_ids,
  tg.review_queue_ids,
  tg.journal_claim_ids,
  tg.journal_open_loop_ids,
  tg.node_statuses
from public.redline_truth_graph_v1(:'iid') tg;

\echo 'Q2) Insert/update defect event with concrete interaction/span/evidence references'
with tg as (
  select *
  from public.redline_truth_graph_v1(:'iid')
), ins as (
  select public.record_redline_defect_event_v1(
    coalesce(tg.primary_defect_type, 'other'),
    case
      when tg.lane_label in ('ingestion', 'segmentation', 'attribution', 'journal', 'projection', 'client')
        then tg.lane_label
      else 'projection'
    end,
    tg.interaction_id,
    tg.thread_id,
    tg.span_ids[1],
    tg.evidence_event_ids[1],
    tg.project_id,
    jsonb_build_object(
      'source', 'proof_pack',
      'lane_label', tg.lane_label,
      'primary_defect_type', tg.primary_defect_type,
      'required_interaction_id', tg.interaction_id,
      'redline_thread_rows', tg.redline_thread_rows
    ),
    null,
    'open'
  ) as defect_event_id
  from tg
)
select defect_event_id from ins;

\echo 'Q3) Show inserted defect event row with concrete pointers'
with latest as (
  select defect_event_id
  from public.redline_defect_events
  where interaction_id = :'iid'
  order by last_seen_at_utc desc
  limit 1
)
select
  rde.defect_event_id,
  rde.defect_type,
  rde.owner_lane,
  rde.interaction_id,
  rde.interaction_uuid,
  rde.thread_id,
  rde.span_id,
  rde.evidence_event_id,
  rde.project_id,
  rde.current_status,
  rde.first_seen_at_utc,
  rde.last_seen_at_utc,
  rde.details
from public.redline_defect_events rde
join latest l on l.defect_event_id = rde.defect_event_id;

\echo 'Q4) Materialized context metadata + staleness rule (anchored to successful pipeline activity)'
select
  v.meta_id,
  v.context_version,
  v.refreshed_at_utc,
  v.source_views,
  v.pipeline_run_id,
  v.activity_anchor_source,
  v.activity_anchor_at_utc,
  v.latest_pipeline_activity_source,
  v.latest_pipeline_activity_at_utc,
  v.staleness_status,
  v.lag_seconds,
  v.refresh_status,
  v.notes
from public.v_project_context_materialization_health_v1 v;

\echo 'Q5) Fast read surface sample (mat_project_context + metadata)'
select
  v.project_id,
  v.project_name,
  v.context_version,
  v.context_refreshed_at_utc,
  v.context_pipeline_run_id,
  v.context_staleness_status,
  v.context_lag_seconds
from public.v_mat_project_context_with_meta_v1 v
order by v.last_interaction_at desc nulls last
limit 5;

\echo 'Q6) REAL_DATA_POINTER helper (one project_id + one interaction_id + latest defect_event_id)'
with project_ptr as (
  select project_id
  from public.v_mat_project_context_with_meta_v1
  where project_id is not null
  order by last_interaction_at desc nulls last
  limit 1
), defect_ptr as (
  select defect_event_id
  from public.redline_defect_events
  where interaction_id = :'iid'
  order by last_seen_at_utc desc
  limit 1
)
select
  (select project_id from project_ptr) as project_id_pointer,
  :'iid'::text as interaction_id_pointer,
  (select defect_event_id from defect_ptr) as defect_event_id_pointer;
