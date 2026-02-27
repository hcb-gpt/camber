-- Hard-drop SLA monitor v1
-- Compounding-systems guardrail:
-- - Quantify stale pending spans (no final attribution decision)
-- - Alert STRAT when hard-drop deadline is breached
-- - Persist heartbeat/alert rows for auditability
--
-- Default assumptions (explicit for reproducibility):
-- - SLA window = 1 hour (pending beyond this is "pending_total")
-- - Hard-drop deadline = 24 hours (pending beyond this is "sla_breach_count")

begin;

create table if not exists public.monitor_alerts (
  id uuid primary key default gen_random_uuid(),
  monitor_name text not null,
  fired_at timestamptz not null default now(),
  metric_snapshot jsonb not null default '{}'::jsonb,
  acked boolean not null default false
);

create index if not exists idx_monitor_alerts_monitor_fired_at
  on public.monitor_alerts (monitor_name, fired_at desc);

create index if not exists idx_monitor_alerts_monitor_acked
  on public.monitor_alerts (monitor_name, acked, fired_at desc);

comment on table public.monitor_alerts is
  'Operational monitor rows (alerts + heartbeats). hard_drop_sla_monitor_v1 writes one row per run.';

comment on column public.monitor_alerts.metric_snapshot is
  'JSON payload with monitor metrics at fire time (pending_total, bucket counts, clusters, breach count, run metadata).';

create or replace function public.get_hard_drop_sla_monitor(
  p_sla_window_hours integer default 1,
  p_hard_drop_deadline_hours integer default 24,
  p_top_n_clusters integer default 10
)
returns table (
  generated_at_utc timestamptz,
  sla_window_hours integer,
  hard_drop_deadline_hours integer,
  pending_total integer,
  pending_by_age_bucket jsonb,
  top_interaction_clusters jsonb,
  sla_breach_count integer
)
language sql
stable
set search_path = public
as $$
with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    coalesce(cs.created_at, now()) as span_created_at_utc
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
),
latest_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    coalesce(sa.applied_at_utc, sa.attributed_at, now()) as attributed_at_utc,
    to_jsonb(sa) as attr_json
  from public.span_attributions sa
  order by sa.span_id, coalesce(sa.applied_at_utc, sa.attributed_at, now()) desc, sa.id desc
),
latest_pending_review as (
  select distinct on (rq.span_id)
    rq.span_id,
    rq.created_at as review_created_at_utc
  from public.review_queue rq
  where rq.status = 'pending'
  order by rq.span_id, rq.created_at desc, rq.id desc
),
pending_spans as (
  select
    s.span_id,
    s.interaction_id,
    coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()) as pending_since_utc,
    extract(
      epoch from (
        now() - coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now())
      )
    ) / 3600.0 as age_hours
  from active_spans s
  left join latest_attr la
    on la.span_id = s.span_id
  left join latest_pending_review rq
    on rq.span_id = s.span_id
  where
    la.span_id is null
    or nullif(la.attr_json->>'decision', '') is null
    or la.attr_json->>'decision' = 'review'
    or coalesce((la.attr_json->>'needs_review')::boolean, false) = true
),
clustered as (
  select
    p.interaction_id,
    count(*)::int as pending_spans,
    round(max(p.age_hours)::numeric, 2) as max_age_hours,
    min(p.pending_since_utc) as oldest_pending_since_utc,
    to_jsonb((array_agg(p.span_id order by p.age_hours desc, p.span_id))[1:5]) as sample_span_ids
  from pending_spans p
  where p.age_hours >= greatest(coalesce(p_sla_window_hours, 1), 0)
  group by p.interaction_id
  order by pending_spans desc, max_age_hours desc, p.interaction_id
  limit greatest(coalesce(p_top_n_clusters, 10), 1)
)
select
  now() at time zone 'utc' as generated_at_utc,
  greatest(coalesce(p_sla_window_hours, 1), 0) as sla_window_hours,
  greatest(coalesce(p_hard_drop_deadline_hours, 24), 0) as hard_drop_deadline_hours,
  count(*) filter (
    where p.age_hours >= greatest(coalesce(p_sla_window_hours, 1), 0)
  )::int as pending_total,
  jsonb_build_object(
    '1h', count(*) filter (where p.age_hours >= 1 and p.age_hours < 6),
    '6h', count(*) filter (where p.age_hours >= 6 and p.age_hours < 24),
    '24h', count(*) filter (where p.age_hours >= 24 and p.age_hours < 48),
    '48h+', count(*) filter (where p.age_hours >= 48)
  ) as pending_by_age_bucket,
  coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'interaction_id', c.interaction_id,
          'pending_spans', c.pending_spans,
          'max_age_hours', c.max_age_hours,
          'oldest_pending_since_utc', c.oldest_pending_since_utc,
          'sample_span_ids', c.sample_span_ids
        )
        order by c.pending_spans desc, c.max_age_hours desc, c.interaction_id
      )
      from clustered c
    ),
    '[]'::jsonb
  ) as top_interaction_clusters,
  count(*) filter (
    where p.age_hours >= greatest(coalesce(p_hard_drop_deadline_hours, 24), 0)
  )::int as sla_breach_count
from pending_spans p;
$$;

comment on function public.get_hard_drop_sla_monitor(integer, integer, integer) is
  'Read-only hard-drop SLA monitor metrics. Defaults: SLA window=1h, hard-drop deadline=24h.';

create or replace view public.v_hard_drop_sla_monitor as
select *
from public.get_hard_drop_sla_monitor();

comment on view public.v_hard_drop_sla_monitor is
  'Single-row hard-drop SLA monitor snapshot: pending_total, pending_by_age_bucket, top_interaction_clusters, sla_breach_count.';

create or replace function public.run_hard_drop_sla_monitor(
  p_sla_window_hours integer default 1,
  p_hard_drop_deadline_hours integer default 24,
  p_top_n_clusters integer default 10,
  p_force_breach boolean default false,
  p_emit_tram boolean default true,
  p_actor text default 'system:hard_drop_sla_monitor'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_monitor_name text := 'hard_drop_sla_monitor_v1';
  v_snapshot record;
  v_effective_breach_count integer := 0;
  v_metric_snapshot jsonb := '{}'::jsonb;
  v_alert_id uuid;
  v_tram_receipt text;
  v_tram_dispatched boolean := false;
  v_tram_error text;
  v_subject text;
  v_priority text;
  v_kind text;
  v_filename text;
  v_content text;
  v_rows integer := 0;
begin
  select *
  into v_snapshot
  from public.get_hard_drop_sla_monitor(
    p_sla_window_hours,
    p_hard_drop_deadline_hours,
    p_top_n_clusters
  );

  v_effective_breach_count := coalesce(v_snapshot.sla_breach_count, 0);
  if coalesce(p_force_breach, false) then
    v_effective_breach_count := greatest(v_effective_breach_count, 1);
  end if;

  v_metric_snapshot := jsonb_build_object(
    'generated_at_utc', v_snapshot.generated_at_utc,
    'sla_window_hours', v_snapshot.sla_window_hours,
    'hard_drop_deadline_hours', v_snapshot.hard_drop_deadline_hours,
    'pending_total', v_snapshot.pending_total,
    'pending_by_age_bucket', coalesce(v_snapshot.pending_by_age_bucket, '{}'::jsonb),
    'top_interaction_clusters', coalesce(v_snapshot.top_interaction_clusters, '[]'::jsonb),
    'sla_breach_count', v_effective_breach_count,
    'raw_sla_breach_count', coalesce(v_snapshot.sla_breach_count, 0),
    'forced_breach', coalesce(p_force_breach, false),
    'actor', coalesce(nullif(trim(p_actor), ''), 'system:hard_drop_sla_monitor'),
    'monitor_name', v_monitor_name
  );

  if v_effective_breach_count > 0 then
    insert into public.monitor_alerts (
      monitor_name,
      fired_at,
      metric_snapshot,
      acked
    )
    values (
      v_monitor_name,
      now(),
      v_metric_snapshot || jsonb_build_object('status', 'alert'),
      false
    )
    returning id into v_alert_id;

    if coalesce(p_emit_tram, true)
       and exists (
         select 1
         from information_schema.tables
         where table_schema = 'public'
           and table_name = 'tram_messages'
       ) then
      begin
        v_tram_receipt := format(
          '%s__hard_drop_sla_monitor_v1__%s',
          case
            when coalesce(p_force_breach, false) then 'test'
            else 'alert'
          end,
          substr(md5(clock_timestamp()::text || random()::text), 1, 12)
        );

        v_subject := case
          when coalesce(p_force_breach, false)
            then 'test__hard_drop_sla_breach__hard_drop_sla_monitor_v1'
          else 'alert__hard_drop_sla_breach__hard_drop_sla_monitor_v1'
        end;
        v_priority := case
          when coalesce(p_force_breach, false) then 'normal'
          else 'high'
        end;
        v_kind := case
          when coalesce(p_force_breach, false) then 'test'
          else 'alert'
        end;
        v_filename := format(
          '%s__to_strat__from_data__prio_%s__kind_%s__thread_compounding-systems__%s.md',
          to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"'),
          v_priority,
          v_kind,
          v_subject
        );
        v_content := concat_ws(
          E'\n',
          format(
            'hard_drop_sla_monitor_v1 breach%s',
            case when coalesce(p_force_breach, false) then ' (TEST_FORCED)' else '' end
          ),
          format('pending_total=%s', coalesce(v_snapshot.pending_total, 0)),
          format('sla_breach_count=%s', v_effective_breach_count),
          format('sla_window_hours=%s', coalesce(v_snapshot.sla_window_hours, p_sla_window_hours)),
          format('hard_drop_deadline_hours=%s', coalesce(v_snapshot.hard_drop_deadline_hours, p_hard_drop_deadline_hours)),
          format('generated_at_utc=%s', v_snapshot.generated_at_utc),
          format('monitor_alert_id=%s', v_alert_id),
          format('top_interaction_clusters=%s', coalesce(v_snapshot.top_interaction_clusters::text, '[]'))
        );

        insert into public.tram_messages (
          receipt,
          "to",
          "from",
          from_agent,
          filename,
          correlation_id,
          turn,
          created_at,
          ack_required,
          acked,
          subject,
          priority,
          kind,
          thread,
          content
        )
        values (
          v_tram_receipt,
          'STRAT',
          'DATA',
          'DATA',
          v_filename,
          'orb_20260223_fa1525dd',
          null,
          now(),
          true,
          false,
          v_subject,
          v_priority,
          v_kind,
          'compounding-systems',
          v_content
        )
        on conflict (receipt) do nothing;

        get diagnostics v_rows = row_count;
        v_tram_dispatched := (v_rows > 0);
        if not v_tram_dispatched then
          v_tram_error := 'tram_insert_conflict_or_noop';
        end if;
      exception
        when others then
          v_tram_dispatched := false;
          v_tram_error := sqlerrm;
      end;
    end if;

    update public.monitor_alerts
    set metric_snapshot = metric_snapshot || jsonb_build_object(
      'tram_dispatched', v_tram_dispatched,
      'tram_receipt', v_tram_receipt,
      'tram_error', v_tram_error
    )
    where id = v_alert_id;
  else
    insert into public.monitor_alerts (
      monitor_name,
      fired_at,
      metric_snapshot,
      acked
    )
    values (
      v_monitor_name,
      now(),
      v_metric_snapshot || jsonb_build_object(
        'status', 'heartbeat',
        'tram_dispatched', false
      ),
      true
    )
    returning id into v_alert_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'monitor_name', v_monitor_name,
    'alert_id', v_alert_id,
    'generated_at_utc', v_snapshot.generated_at_utc,
    'pending_total', coalesce(v_snapshot.pending_total, 0),
    'sla_breach_count', v_effective_breach_count,
    'forced_breach', coalesce(p_force_breach, false),
    'tram_dispatched', v_tram_dispatched,
    'tram_receipt', v_tram_receipt,
    'tram_error', v_tram_error,
    'heartbeat_only', (v_effective_breach_count = 0)
  );
end;
$$;

comment on function public.run_hard_drop_sla_monitor(integer, integer, integer, boolean, boolean, text) is
  'Writes monitor_alerts heartbeat/alert rows hourly. On breach (> deadline), inserts TRAM alert to STRAT when tram_messages table is available.';

grant select on public.monitor_alerts to service_role;
grant insert, update on public.monitor_alerts to service_role;
grant execute on function public.get_hard_drop_sla_monitor(integer, integer, integer) to service_role;
grant execute on function public.run_hard_drop_sla_monitor(integer, integer, integer, boolean, boolean, text) to service_role;
grant select on public.v_hard_drop_sla_monitor to anon, authenticated, service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'hard_drop_sla_monitor_hourly'
      ) then
        perform cron.schedule(
          'hard_drop_sla_monitor_hourly',
          '5 * * * *',
          $cron$select public.run_hard_drop_sla_monitor(1, 24, 10, false, true, 'system:hard_drop_sla_monitor_cron');$cron$
        );
      end if;
    exception
      when others then
        raise notice 'hard_drop_sla_monitor cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
