-- Proof pack for deploy receipts + overwrite guard + monitoring.

select
  function_slug,
  git_sha,
  version_tag,
  deployed_at,
  git_commit_ts,
  accepted,
  rejection_reason,
  override_used,
  previous_git_sha,
  previous_deployed_at,
  deployer_session,
  created_at
from public.edge_deploy_receipts
where function_slug in ('redline-thread', 'segment-call')
order by function_slug, deployed_at, created_at;

select
  function_slug,
  count(*) filter (where accepted = true)::int as accepted_receipts,
  count(*) filter (where accepted = false)::int as blocked_attempts
from public.edge_deploy_receipts
where function_slug in ('redline-thread', 'segment-call')
group by function_slug
order by function_slug;

select
  alert_type,
  function_slug,
  git_sha,
  version_tag,
  deployed_at,
  deployer_session,
  detail
from public.v_edge_deploy_guard_alerts
where function_slug in ('redline-thread', 'segment-call')
order by deployed_at desc;

select
  generated_at_utc,
  older_sha_blocked_24h,
  rapid_redeploy_events_24h,
  rapid_redeploy_functions
from public.v_edge_deploy_guard_summary;

select
  id,
  monitor_name,
  fired_at,
  acked,
  metric_snapshot
from public.monitor_alerts
where monitor_name = 'edge_deploy_guard_monitor_v1'
order by fired_at desc
limit 5;

