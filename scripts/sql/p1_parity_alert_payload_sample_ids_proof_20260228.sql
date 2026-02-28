-- Proof pack: parity monitor alert payload sample IDs (P1)
-- Usage:
--   /usr/local/opt/libpq/bin/psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/p1_parity_alert_payload_sample_ids_proof_20260228.sql

\echo 'Q1) View now includes sample_interaction_ids (Beside parity view)'
select
  generated_at_utc,
  missing_count,
  sample_interaction_ids,
  example_tuples
from public.v_beside_calls_missing_in_interactions_24h;

\echo 'Q2) Verify Beside sample_interaction_ids are present in Beside view examples'
with v as (
  select
    sample_interaction_ids,
    example_tuples
  from public.v_beside_calls_missing_in_interactions_24h
),
ids as (
  select value as interaction_id
  from v, lateral jsonb_array_elements_text(v.sample_interaction_ids)
),
examples as (
  select elem->>'camber_interaction_id' as interaction_id
  from v, lateral jsonb_array_elements(v.example_tuples) elem
)
select
  ids.interaction_id,
  exists (
    select 1
    from examples e
    where e.interaction_id = ids.interaction_id
  ) as present_in_view_examples
from ids;

\echo 'Q3) Top 5 interaction_ids from projection-missing view'
with top_ids as (
  select distinct
    v.interaction_id,
    v.event_at_utc
  from public.v_interactions_missing_in_redline_thread_24h v
  where coalesce(v.interaction_id, '') <> ''
  order by v.event_at_utc desc, v.interaction_id
  limit 5
)
select
  jsonb_agg(to_jsonb(interaction_id) order by event_at_utc desc) as sample_interaction_ids_interactions_missing_in_redline
from top_ids;

\echo 'Q4) Run monitor (emit_tram=true) to generate next alert payload'
select public.run_beside_parity_monitor_v1(0, true, 'data-1-p1-sample-ids-proof') as monitor_result;

\echo 'Q5) Latest monitor_alerts payload includes sample IDs + invariants doc path'
select
  ma.id as monitor_alert_id,
  ma.fired_at,
  ma.metric_snapshot->'sample_interaction_ids_beside_missing_in_interactions_24h' as sample_interaction_ids_beside,
  ma.metric_snapshot->'sample_interaction_ids_interactions_missing_in_redline_thread_24h' as sample_interaction_ids_projection,
  ma.metric_snapshot->>'invariants_doc_path' as invariants_doc_path,
  ma.metric_snapshot->>'status' as status,
  ma.metric_snapshot->>'tram_receipt' as tram_receipt
from public.monitor_alerts ma
where ma.monitor_name = 'beside_parity_monitor_v1'
order by ma.fired_at desc
limit 1;

\echo 'Q6) Latest TRAM alert content contains inline sample IDs + doc path'
select
  tm.receipt,
  tm.created_at,
  tm.content
from public.tram_messages tm
where tm.subject = 'alert__beside_parity_monitor_v1'
order by tm.created_at desc
limit 1;
