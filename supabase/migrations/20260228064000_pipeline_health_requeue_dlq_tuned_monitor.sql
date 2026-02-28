-- Pipeline-health queue extension:
-- 1) Idempotent requeue RPC
-- 2) Dead-letter bucket + sweep
-- 3) Tuned alert monitor (growth + oldest-age)

create table if not exists public.hard_drop_dlq (
  id uuid primary key default gen_random_uuid(),
  span_id uuid not null unique references public.conversation_spans(id) on delete cascade,
  interaction_id text not null,
  first_enqueued_at timestamptz not null default now(),
  last_enqueued_at timestamptz not null default now(),
  retry_count integer not null default 1,
  age_hours numeric,
  dlq_reason text not null default 'retry_threshold_exceeded',
  status text not null default 'open' check (status in ('open', 'resolved')),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_hard_drop_dlq_status_last
  on public.hard_drop_dlq (status, last_enqueued_at desc);

create or replace view public.v_hard_drop_dlq_open as
select
  d.id,
  d.span_id,
  d.interaction_id,
  d.first_enqueued_at,
  d.last_enqueued_at,
  d.retry_count,
  d.age_hours,
  d.dlq_reason,
  d.metadata,
  d.created_at,
  d.updated_at
from public.hard_drop_dlq d
where d.status = 'open'
order by d.last_enqueued_at desc;

comment on table public.hard_drop_dlq is
'Dead-letter bucket for hard-drop pending spans that repeatedly fail/requeue past thresholds.';

comment on view public.v_hard_drop_dlq_open is
'Open hard-drop DLQ entries for operator monitoring.';

create or replace function public.requeue_hard_drop_span(
  p_span_id uuid,
  p_actor text default 'system:data_requeue',
  p_reason_codes text[] default array['manual_requeue']
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_span record;
  v_existing record;
  v_reason_codes text[] := coalesce(p_reason_codes, array['manual_requeue']::text[]);
  v_review_id uuid;
  v_hit_count integer;
  v_action text;
begin
  select
    cs.id as span_id,
    cs.interaction_id,
    coalesce(cs.is_superseded, false) as is_superseded
  into v_span
  from public.conversation_spans cs
  where cs.id = p_span_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'span_not_found', 'span_id', p_span_id);
  end if;
  if v_span.is_superseded then
    return jsonb_build_object('ok', false, 'error', 'span_is_superseded', 'span_id', p_span_id);
  end if;

  select *
  into v_existing
  from public.review_queue rq
  where rq.span_id = p_span_id
  order by rq.created_at desc, rq.id desc
  limit 1;

  if found then
    update public.review_queue rq
    set
      interaction_id = coalesce(rq.interaction_id, v_span.interaction_id),
      reasons = (
        select array_agg(distinct x)
        from unnest(coalesce(rq.reasons, array[]::text[]) || v_reason_codes) as x
      ),
      reason_codes = (
        select array_agg(distinct x)
        from unnest(coalesce(rq.reason_codes, array[]::text[]) || v_reason_codes) as x
      ),
      status = 'pending',
      module = coalesce(rq.module, 'attribution'),
      requires_reprocess = true,
      resolved_at = null,
      resolved_by = null,
      resolution_action = null,
      resolution_notes = null,
      updated_at = now(),
      hit_count = coalesce(rq.hit_count, 1) + 1,
      batch_run_id = coalesce(rq.batch_run_id, 'manual_hard_drop_requeue'),
      context_payload = coalesce(rq.context_payload, '{}'::jsonb) || jsonb_build_object(
        'last_requeue_actor', coalesce(nullif(trim(p_actor), ''), 'system:data_requeue'),
        'last_requeue_at_utc', now()
      )
    where rq.id = v_existing.id
    returning rq.id, coalesce(rq.hit_count, 1) into v_review_id, v_hit_count;

    v_action := 'updated';
  else
    insert into public.review_queue (
      interaction_id,
      span_id,
      reasons,
      reason_codes,
      context_payload,
      status,
      module,
      requires_reprocess,
      hit_count,
      batch_run_id,
      dedupe_key
    )
    values (
      v_span.interaction_id,
      v_span.span_id,
      v_reason_codes,
      v_reason_codes,
      jsonb_build_object(
        'created_by_actor', coalesce(nullif(trim(p_actor), ''), 'system:data_requeue'),
        'created_at_utc', now()
      ),
      'pending',
      'attribution',
      true,
      1,
      'manual_hard_drop_requeue',
      'manual_requeue:' || v_span.span_id::text
    )
    returning id, hit_count into v_review_id, v_hit_count;

    v_action := 'inserted';
  end if;

  return jsonb_build_object(
    'ok', true,
    'action', v_action,
    'review_queue_id', v_review_id,
    'span_id', v_span.span_id,
    'interaction_id', v_span.interaction_id,
    'hit_count', v_hit_count
  );
end;
$$;

comment on function public.requeue_hard_drop_span(uuid, text, text[]) is
'Idempotent hard-drop requeue tool: inserts/updates pending review_queue row for a span, increments hit_count, and clears prior resolution.';

create or replace function public.run_hard_drop_dlq_sweep(
  p_retry_threshold integer default 3,
  p_age_hours numeric default 24,
  p_actor text default 'system:hard_drop_dlq_sweep'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_candidates integer := 0;
  v_upserted integer := 0;
  v_open_count integer := 0;
begin
  with candidates as (
    select
      rq.span_id,
      rq.interaction_id,
      coalesce(rq.hit_count, 1) as retry_count,
      extract(epoch from (now() - coalesce(rq.updated_at, rq.created_at))) / 3600.0 as age_hours
    from public.review_queue rq
    join public.conversation_spans cs on cs.id = rq.span_id
    where rq.status = 'pending'
      and coalesce(cs.is_superseded, false) = false
      and rq.interaction_id not like 'cll_SHADOW%'
      and rq.interaction_id not like 'cll_RACECHK%'
      and rq.interaction_id not like 'cll_DEV%'
      and rq.interaction_id not like 'cll_CHAIN%'
      and coalesce(rq.hit_count, 1) >= greatest(coalesce(p_retry_threshold, 3), 1)
      and extract(epoch from (now() - coalesce(rq.updated_at, rq.created_at))) / 3600.0 >= greatest(coalesce(p_age_hours, 24), 1)
  ),
  upserted as (
    insert into public.hard_drop_dlq (
      span_id,
      interaction_id,
      first_enqueued_at,
      last_enqueued_at,
      retry_count,
      age_hours,
      dlq_reason,
      status,
      metadata,
      updated_at
    )
    select
      c.span_id,
      c.interaction_id,
      now(),
      now(),
      c.retry_count,
      round(c.age_hours::numeric, 3),
      'retry_threshold_exceeded',
      'open',
      jsonb_build_object(
        'actor', coalesce(nullif(trim(p_actor), ''), 'system:hard_drop_dlq_sweep'),
        'retry_threshold', greatest(coalesce(p_retry_threshold, 3), 1),
        'age_hours_threshold', greatest(coalesce(p_age_hours, 24), 1),
        'swept_at_utc', now()
      ),
      now()
    from candidates c
    on conflict (span_id) do update
      set
        interaction_id = excluded.interaction_id,
        last_enqueued_at = now(),
        retry_count = greatest(public.hard_drop_dlq.retry_count, excluded.retry_count),
        age_hours = excluded.age_hours,
        dlq_reason = excluded.dlq_reason,
        status = 'open',
        metadata = coalesce(public.hard_drop_dlq.metadata, '{}'::jsonb) || excluded.metadata,
        updated_at = now()
    returning span_id
  )
  select
    (select count(*)::int from candidates),
    (select count(*)::int from upserted)
  into v_candidates, v_upserted;

  select count(*)::int
  into v_open_count
  from public.hard_drop_dlq
  where status = 'open';

  return jsonb_build_object(
    'ok', true,
    'candidates', v_candidates,
    'upserted', v_upserted,
    'open_dlq_count', v_open_count
  );
end;
$$;

comment on function public.run_hard_drop_dlq_sweep(integer, numeric, text) is
'Promotes stale/retried pending spans into hard_drop_dlq for operator visibility.';

create or replace function public.run_hard_drop_sla_monitor_tuned(
  p_growth_threshold integer default 10,
  p_oldest_age_hours numeric default 24,
  p_actor text default 'system:hard_drop_sla_monitor_tuned'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_monitor_name text := 'hard_drop_sla_monitor_tuned_v1';
  v_snapshot record;
  v_previous_pending integer := 0;
  v_pending_growth integer := 0;
  v_oldest_age_hours numeric := 0;
  v_is_alert boolean := false;
  v_alert_id uuid;
begin
  select *
  into v_snapshot
  from public.get_hard_drop_sla_monitor();

  select
    coalesce((ma.metric_snapshot->>'pending_total')::integer, 0)
  into v_previous_pending
  from public.monitor_alerts ma
  where ma.monitor_name = v_monitor_name
  order by ma.fired_at desc
  limit 1;

  if coalesce(jsonb_array_length(v_snapshot.top_interaction_clusters), 0) > 0 then
    v_oldest_age_hours := coalesce((v_snapshot.top_interaction_clusters->0->>'max_age_hours')::numeric, 0);
  end if;

  v_pending_growth := coalesce(v_snapshot.pending_total, 0) - coalesce(v_previous_pending, 0);

  v_is_alert :=
    v_oldest_age_hours >= greatest(coalesce(p_oldest_age_hours, 24), 1)
    and v_pending_growth >= greatest(coalesce(p_growth_threshold, 10), 1);

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
      'actor', coalesce(nullif(trim(p_actor), ''), 'system:hard_drop_sla_monitor_tuned'),
      'status', case when v_is_alert then 'alert' else 'heartbeat' end,
      'pending_total', coalesce(v_snapshot.pending_total, 0),
      'pending_growth', v_pending_growth,
      'previous_pending_total', coalesce(v_previous_pending, 0),
      'oldest_age_hours', v_oldest_age_hours,
      'growth_threshold', greatest(coalesce(p_growth_threshold, 10), 1),
      'oldest_age_threshold_hours', greatest(coalesce(p_oldest_age_hours, 24), 1),
      'raw_sla_breach_count', coalesce(v_snapshot.sla_breach_count, 0)
    ),
    not v_is_alert
  )
  returning id into v_alert_id;

  return jsonb_build_object(
    'ok', true,
    'monitor_name', v_monitor_name,
    'alert_id', v_alert_id,
    'is_alert', v_is_alert,
    'pending_total', coalesce(v_snapshot.pending_total, 0),
    'pending_growth', v_pending_growth,
    'oldest_age_hours', v_oldest_age_hours
  );
end;
$$;

comment on function public.run_hard_drop_sla_monitor_tuned(integer, numeric, text) is
'Tuned hard-drop monitor: alerts only when backlog growth and oldest-age thresholds are both breached.';

grant select on public.hard_drop_dlq to service_role;
grant select on public.v_hard_drop_dlq_open to service_role;
grant execute on function public.requeue_hard_drop_span(uuid, text, text[]) to service_role;
grant execute on function public.run_hard_drop_dlq_sweep(integer, numeric, text) to service_role;
grant execute on function public.run_hard_drop_sla_monitor_tuned(integer, numeric, text) to service_role;

do $do$
declare
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      select jobid
      into v_job_id
      from cron.job
      where jobname = 'hard_drop_sla_monitor_tuned_hourly'
      order by jobid desc
      limit 1;

      if v_job_id is not null then
        perform cron.unschedule(v_job_id);
      end if;

      perform cron.schedule(
        'hard_drop_sla_monitor_tuned_hourly',
        '10 * * * *',
        $$select public.run_hard_drop_sla_monitor_tuned();$$
      );
    exception
      when others then
        raise notice 'hard_drop_sla_monitor_tuned_hourly cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

