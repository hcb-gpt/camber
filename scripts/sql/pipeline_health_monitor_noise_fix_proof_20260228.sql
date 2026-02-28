-- Proof pack: pipeline-health alert-noise fixes (DATA-1)
-- Usage:
--   scripts/query.sh --file scripts/sql/pipeline_health_monitor_noise_fix_proof_20260228.sql

\echo 'Q1) Hard-drop monitor cron jobs (legacy should be removed; tuned should remain active)'
select
  jobid,
  jobname,
  schedule,
  active,
  command
from cron.job
where jobname ilike '%hard_drop_sla_monitor%'
order by jobid;

\echo 'Q2) Latest hard-drop and redline monitor snapshots'
select
  fired_at,
  monitor_name,
  acked,
  metric_snapshot->>'status' as status,
  metric_snapshot->>'journal_stale' as journal_stale,
  metric_snapshot->>'journal_activity_age_minutes' as journal_activity_age_minutes,
  metric_snapshot->>'journal_claim_age_minutes' as journal_claim_age_minutes,
  metric_snapshot->>'pending_total' as pending_total,
  metric_snapshot->>'pending_growth' as pending_growth,
  metric_snapshot->>'oldest_age_hours' as oldest_age_hours
from public.monitor_alerts
where monitor_name in ('redline_refresh_monitor_v1', 'hard_drop_sla_monitor_tuned_v1', 'hard_drop_sla_monitor_v1')
order by fired_at desc
limit 15;

\echo 'Q3) Current hard-drop SLA snapshot'
select
  generated_at_utc,
  pending_total,
  pending_by_age_bucket,
  sla_breach_count
from public.v_hard_drop_sla_monitor;
