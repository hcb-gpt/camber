-- Deploy receipts + overwrite guard + monitoring primitives.
-- Purpose: prevent silent regressions from older-sha redeploys.

create table if not exists public.edge_deploy_receipts (
  id uuid primary key default gen_random_uuid(),
  function_slug text not null,
  git_sha text not null,
  deployed_at timestamptz not null default now(),
  deployer_session text not null,
  version_tag text,
  git_commit_ts timestamptz,
  accepted boolean not null default true,
  rejection_reason text,
  override_used boolean not null default false,
  previous_git_sha text,
  previous_deployed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check (length(trim(function_slug)) > 0),
  check (length(trim(git_sha)) >= 7),
  check (accepted or rejection_reason is not null)
);

create index if not exists idx_edge_deploy_receipts_fn_deployed
  on public.edge_deploy_receipts (function_slug, deployed_at desc);

create index if not exists idx_edge_deploy_receipts_fn_accept_created
  on public.edge_deploy_receipts (function_slug, accepted, created_at desc);

create index if not exists idx_edge_deploy_receipts_alert_window
  on public.edge_deploy_receipts (created_at desc, accepted, rejection_reason);

comment on table public.edge_deploy_receipts is
'Durable deploy receipts + blocked deploy attempts for edge functions. Used to prevent older-sha overwrite regressions.';

create or replace function public.record_edge_deploy_receipt(
  p_function_slug text,
  p_git_sha text,
  p_deployer_session text,
  p_version_tag text default null,
  p_deployed_at timestamptz default now(),
  p_git_commit_ts timestamptz default null,
  p_allow_older_sha boolean default false,
  p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_latest record;
  v_function_slug text := lower(trim(coalesce(p_function_slug, '')));
  v_git_sha text := trim(coalesce(p_git_sha, ''));
  v_deployer_session text := trim(coalesce(p_deployer_session, ''));
  v_accepted boolean := true;
  v_rejection_reason text := null;
  v_rapid_redeploy boolean := false;
  v_id uuid;
begin
  if v_function_slug = '' then
    raise exception 'function_slug_required';
  end if;
  if length(v_git_sha) < 7 then
    raise exception 'git_sha_too_short';
  end if;
  if v_deployer_session = '' then
    raise exception 'deployer_session_required';
  end if;

  select
    r.git_sha,
    r.deployed_at,
    r.git_commit_ts
  into v_latest
  from public.edge_deploy_receipts r
  where r.function_slug = v_function_slug
    and r.accepted = true
  order by r.deployed_at desc, r.created_at desc
  limit 1;

  if found then
    v_rapid_redeploy :=
      p_deployed_at >= v_latest.deployed_at
      and p_deployed_at - v_latest.deployed_at <= interval '15 minutes';

    if not coalesce(p_allow_older_sha, false)
       and v_latest.git_sha <> v_git_sha
       and v_latest.git_commit_ts is not null then
      if p_git_commit_ts is null then
        v_accepted := false;
        v_rejection_reason := 'missing_commit_ts_cannot_compare';
      elsif p_git_commit_ts < v_latest.git_commit_ts then
        v_accepted := false;
        v_rejection_reason := 'older_sha_blocked';
      end if;
    end if;
  end if;

  insert into public.edge_deploy_receipts (
    function_slug,
    git_sha,
    deployed_at,
    deployer_session,
    version_tag,
    git_commit_ts,
    accepted,
    rejection_reason,
    override_used,
    previous_git_sha,
    previous_deployed_at,
    metadata
  )
  values (
    v_function_slug,
    v_git_sha,
    coalesce(p_deployed_at, now()),
    v_deployer_session,
    nullif(trim(coalesce(p_version_tag, '')), ''),
    p_git_commit_ts,
    v_accepted,
    v_rejection_reason,
    coalesce(p_allow_older_sha, false),
    v_latest.git_sha,
    v_latest.deployed_at,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'rapid_redeploy', v_rapid_redeploy,
      'ingested_at_utc', now()
    )
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'receipt_id', v_id,
    'accepted', v_accepted,
    'rejection_reason', v_rejection_reason,
    'rapid_redeploy', v_rapid_redeploy,
    'function_slug', v_function_slug,
    'git_sha', v_git_sha
  );
end;
$$;

comment on function public.record_edge_deploy_receipt(text, text, text, text, timestamptz, timestamptz, boolean, jsonb) is
'Writes an edge deploy receipt and blocks older-sha deploy attempts when commit_ts indicates regression (unless override flag is true).';

create or replace view public.v_edge_deploy_guard_alerts as
with recent as (
  select *
  from public.edge_deploy_receipts
  where created_at >= now() - interval '24 hours'
),
older_sha_attempts as (
  select
    'older_sha_blocked'::text as alert_type,
    r.function_slug,
    r.git_sha,
    r.version_tag,
    r.deployed_at,
    r.deployer_session,
    r.rejection_reason as detail
  from recent r
  where r.accepted = false
    and r.rejection_reason in ('older_sha_blocked', 'missing_commit_ts_cannot_compare')
),
rapid_redeploys as (
  select
    'rapid_redeploy'::text as alert_type,
    r.function_slug,
    r.git_sha,
    r.version_tag,
    r.deployed_at,
    r.deployer_session,
    format('previous_sha=%s previous_deployed_at=%s', coalesce(r.previous_git_sha, 'none'), r.previous_deployed_at)::text as detail
  from recent r
  where r.accepted = true
    and r.previous_deployed_at is not null
    and r.deployed_at >= r.previous_deployed_at
    and r.deployed_at - r.previous_deployed_at <= interval '15 minutes'
)
select * from older_sha_attempts
union all
select * from rapid_redeploys
order by deployed_at desc;

comment on view public.v_edge_deploy_guard_alerts is
'24h deploy-guard alerts: blocked older-sha attempts and rapid redeploy events (<=15m since prior accepted deploy).';

create or replace view public.v_edge_deploy_guard_summary as
with recent as (
  select *
  from public.edge_deploy_receipts
  where created_at >= now() - interval '24 hours'
),
rapid as (
  select
    function_slug,
    count(*)::int as rapid_count
  from recent
  where accepted = true
    and previous_deployed_at is not null
    and deployed_at >= previous_deployed_at
    and deployed_at - previous_deployed_at <= interval '15 minutes'
  group by function_slug
)
select
  now() as generated_at_utc,
  count(*) filter (
    where accepted = false
      and rejection_reason in ('older_sha_blocked', 'missing_commit_ts_cannot_compare')
  )::int as older_sha_blocked_24h,
  count(*) filter (
    where accepted = true
      and previous_deployed_at is not null
      and deployed_at >= previous_deployed_at
      and deployed_at - previous_deployed_at <= interval '15 minutes'
  )::int as rapid_redeploy_events_24h,
  coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'function_slug', r.function_slug,
          'rapid_count', r.rapid_count
        )
        order by r.rapid_count desc, r.function_slug
      )
      from rapid r
    ),
    '[]'::jsonb
  ) as rapid_redeploy_functions
from recent;

comment on view public.v_edge_deploy_guard_summary is
'24h summary for deploy guard monitoring: blocked older-sha attempts and rapid redeploy counts by function.';

create or replace function public.run_edge_deploy_guard_monitor(
  p_actor text default 'system:edge_deploy_guard_monitor'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_monitor_name text := 'edge_deploy_guard_monitor_v1';
  v_summary record;
  v_is_alert boolean := false;
  v_alert_id uuid;
begin
  select *
  into v_summary
  from public.v_edge_deploy_guard_summary;

  v_is_alert := coalesce(v_summary.older_sha_blocked_24h, 0) > 0
                or coalesce(v_summary.rapid_redeploy_events_24h, 0) >= 3;

  insert into public.monitor_alerts (
    monitor_name,
    fired_at,
    metric_snapshot,
    acked
  )
  values (
    v_monitor_name,
    now(),
    jsonb_build_object(
      'monitor_name', v_monitor_name,
      'checked_at_utc', now(),
      'actor', coalesce(nullif(trim(p_actor), ''), 'system:edge_deploy_guard_monitor'),
      'status', case when v_is_alert then 'alert' else 'heartbeat' end,
      'older_sha_blocked_24h', coalesce(v_summary.older_sha_blocked_24h, 0),
      'rapid_redeploy_events_24h', coalesce(v_summary.rapid_redeploy_events_24h, 0),
      'rapid_redeploy_functions', coalesce(v_summary.rapid_redeploy_functions, '[]'::jsonb)
    ),
    not v_is_alert
  )
  returning id into v_alert_id;

  return jsonb_build_object(
    'ok', true,
    'monitor_name', v_monitor_name,
    'alert_id', v_alert_id,
    'is_alert', v_is_alert,
    'older_sha_blocked_24h', coalesce(v_summary.older_sha_blocked_24h, 0),
    'rapid_redeploy_events_24h', coalesce(v_summary.rapid_redeploy_events_24h, 0)
  );
end;
$$;

comment on function public.run_edge_deploy_guard_monitor(text) is
'Writes monitor_alerts heartbeat/alert for deploy guard anomalies (older-sha blocks, rapid redeploy bursts).';

grant select on public.edge_deploy_receipts to service_role;
grant execute on function public.record_edge_deploy_receipt(text, text, text, text, timestamptz, timestamptz, boolean, jsonb) to service_role;
grant select on public.v_edge_deploy_guard_alerts to service_role;
grant select on public.v_edge_deploy_guard_summary to service_role;
grant execute on function public.run_edge_deploy_guard_monitor(text) to service_role;

