-- Proof pack: Redline pipeline harness reconciliation v1
-- Usage:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/redline_pipeline_harness_reconciliation_v1_proof_20260228.sql

\echo 'Q1) Ingestion parity summary (Beside call events missing in interactions)'
select
  generated_at_utc,
  window_start_utc,
  missing_count,
  example_tuples
from public.v_beside_calls_missing_in_interactions_24h;

\echo 'Q2) Projection parity summary (interactions missing in redline_thread)'
select
  count(*)::integer as missing_interactions_count,
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'interaction_id', x.interaction_id,
        'channel', x.channel,
        'event_at_utc', x.event_at_utc,
        'ingested_at_utc', x.ingested_at_utc,
        'contact_id', x.contact_id,
        'contact_phone', x.contact_phone
      )
      order by x.event_at_utc desc
    ) filter (where x.rn <= 20),
    '[]'::jsonb
  ) as example_missing_interactions
from (
  select
    v.*,
    row_number() over (order by v.event_at_utc desc, v.interaction_id) as rn
  from public.v_interactions_missing_in_redline_thread_24h v
) x;

\echo 'Q3) Run parity monitor (threshold=0, emit_tram=false) to produce monitor_alert_id'
select public.run_beside_parity_monitor_v1(0, false, 'data-1-proof') as monitor_result;

\echo 'Q4) Latest parity monitor alert payload'
select
  ma.id as monitor_alert_id,
  ma.fired_at,
  ma.acked,
  ma.metric_snapshot
from public.monitor_alerts ma
where ma.monitor_name = 'beside_parity_monitor_v1'
order by ma.fired_at desc
limit 1;

\echo 'Q5) Cron schedule state'
select
  jobid,
  jobname,
  schedule,
  active,
  command
from cron.job
where jobname = 'beside_parity_monitor_v1_15m';
