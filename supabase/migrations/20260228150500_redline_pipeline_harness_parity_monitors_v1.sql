-- Redline pipeline harness parity monitors v1
-- Purpose:
-- 1) Surface Beside call events missing in interactions (ingestion gap signal)
-- 2) Surface interactions call rows missing in redline_thread (projection gap signal)
-- 3) Schedule parity monitor that writes monitor_alerts and optionally emits TRAM alerts

create or replace view public.v_beside_calls_missing_in_interactions_24h as
with beside_calls as (
  select
    b.beside_event_id,
    b.beside_event_type,
    b.occurred_at_utc,
    b.ingested_at_utc,
    b.source,
    b.camber_interaction_id,
    right(regexp_replace(coalesce(b.contact_phone_e164, ''), '\D', '', 'g'), 10) as phone10
  from public.beside_thread_events b
  where lower(coalesce(b.beside_event_type, '')) like 'call%'
    and b.occurred_at_utc >= now() - interval '24 hours'
),
interactions_calls as (
  select
    i.interaction_id,
    i.event_at_utc,
    i.ingested_at_utc,
    i.channel,
    i.contact_id,
    i.contact_phone,
    right(regexp_replace(coalesce(i.contact_phone, ''), '\D', '', 'g'), 10) as phone10
  from public.interactions i
  where lower(coalesce(i.channel, '')) in ('call', 'phone')
    and coalesce(i.is_shadow, false) = false
    and i.event_at_utc >= now() - interval '24 hours'
),
missing as (
  select
    b.beside_event_id,
    b.beside_event_type,
    b.occurred_at_utc,
    b.ingested_at_utc as beside_ingested_at_utc,
    b.source as beside_source,
    b.phone10,
    b.camber_interaction_id
  from beside_calls b
  left join lateral (
    select i.interaction_id
    from interactions_calls i
    where i.phone10 = b.phone10
      and i.event_at_utc between b.occurred_at_utc - interval '120 seconds'
                            and b.occurred_at_utc + interval '120 seconds'
    order by abs(extract(epoch from (i.event_at_utc - b.occurred_at_utc))), i.event_at_utc desc
    limit 1
  ) i_match on true
  where i_match.interaction_id is null
),
ranked as (
  select
    m.*,
    row_number() over (order by m.occurred_at_utc desc, m.beside_event_id) as rn
  from missing m
)
select
  now() as generated_at_utc,
  now() - interval '24 hours' as window_start_utc,
  count(*)::integer as missing_count,
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'beside_event_id', r.beside_event_id,
        'beside_event_type', r.beside_event_type,
        'phone10', r.phone10,
        'occurred_at_utc', r.occurred_at_utc,
        'beside_ingested_at_utc', r.beside_ingested_at_utc,
        'source', r.beside_source,
        'camber_interaction_id', r.camber_interaction_id
      )
      order by r.occurred_at_utc desc
    ) filter (where r.rn <= 20),
    '[]'::jsonb
  ) as example_tuples
from ranked r;

comment on view public.v_beside_calls_missing_in_interactions_24h is
'24h parity summary: Beside call events that have no matching interactions(call/phone) row within ±120 seconds on normalized phone.';

create or replace view public.v_interactions_missing_in_redline_thread_24h as
with interactions_calls as (
  select
    i.interaction_id,
    i.event_at_utc,
    i.ingested_at_utc,
    i.channel,
    i.contact_id,
    i.contact_name,
    i.contact_phone
  from public.interactions i
  where lower(coalesce(i.channel, '')) in ('call', 'phone')
    and coalesce(i.is_shadow, false) = false
    and i.event_at_utc >= now() - interval '24 hours'
),
redline_calls as (
  select distinct
    rt.interaction_id::text as interaction_id
  from public.redline_thread rt
  where lower(coalesce(rt.interaction_type, '')) like 'call%'
    and rt.event_at_utc >= now() - interval '24 hours'
)
select
  now() as generated_at_utc,
  i.interaction_id,
  i.channel,
  i.event_at_utc,
  i.ingested_at_utc,
  i.contact_id,
  i.contact_name,
  i.contact_phone
from interactions_calls i
left join redline_calls r
  on r.interaction_id = i.interaction_id
where r.interaction_id is null
order by i.event_at_utc desc, i.interaction_id;

comment on view public.v_interactions_missing_in_redline_thread_24h is
'24h parity detail: interactions(call/phone) rows missing from redline_thread call projection.';

create or replace function public.run_beside_parity_monitor_v1(
  p_missing_threshold integer default 0,
  p_emit_tram boolean default true,
  p_actor text default 'system:beside_parity_monitor_v1'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_monitor_name text := 'beside_parity_monitor_v1';
  v_beside_missing_count integer := 0;
  v_interactions_missing_count integer := 0;
  v_beside_examples jsonb := '[]'::jsonb;
  v_interactions_examples jsonb := '[]'::jsonb;
  v_is_alert boolean := false;
  v_alert_id uuid;
  v_tram_receipt text;
  v_tram_dispatched boolean := false;
  v_tram_error text;
  v_subject text;
  v_priority text := 'high';
  v_kind text := 'alert';
  v_filename text;
  v_content text;
  v_rows integer := 0;
begin
  select
    coalesce(v.missing_count, 0),
    coalesce(v.example_tuples, '[]'::jsonb)
  into v_beside_missing_count, v_beside_examples
  from public.v_beside_calls_missing_in_interactions_24h v;

  select
    count(*)::integer,
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
    )
  into v_interactions_missing_count, v_interactions_examples
  from (
    select
      v.*,
      row_number() over (order by v.event_at_utc desc, v.interaction_id) as rn
    from public.v_interactions_missing_in_redline_thread_24h v
  ) x;

  v_is_alert :=
    v_beside_missing_count > greatest(coalesce(p_missing_threshold, 0), 0)
    or v_interactions_missing_count > greatest(coalesce(p_missing_threshold, 0), 0);

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
      'actor', coalesce(nullif(trim(p_actor), ''), 'system:beside_parity_monitor_v1'),
      'status', case when v_is_alert then 'alert' else 'heartbeat' end,
      'missing_threshold', greatest(coalesce(p_missing_threshold, 0), 0),
      'beside_calls_missing_in_interactions_24h', v_beside_missing_count,
      'interactions_missing_in_redline_thread_24h', v_interactions_missing_count,
      'example_beside_missing_tuples', v_beside_examples,
      'example_interactions_missing_rows', v_interactions_examples
    ),
    not v_is_alert
  )
  returning id into v_alert_id;

  if v_is_alert
     and coalesce(p_emit_tram, true)
     and exists (
       select 1
       from information_schema.tables
       where table_schema = 'public'
         and table_name = 'tram_messages'
     ) then
    begin
      v_tram_receipt := format(
        'alert__beside_parity_monitor_v1__%s',
        substr(md5(clock_timestamp()::text || random()::text), 1, 12)
      );
      v_subject := 'alert__beside_parity_monitor_v1';
      v_filename := format(
        '%s__to_strat__from_data__prio_%s__kind_%s__thread_pipeline-harness__%s.md',
        to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"'),
        v_priority,
        v_kind,
        v_subject
      );
      v_content := concat_ws(
        E'\n',
        'beside_parity_monitor_v1 threshold breached',
        format('monitor_alert_id=%s', v_alert_id),
        format('beside_calls_missing_in_interactions_24h=%s', v_beside_missing_count),
        format('interactions_missing_in_redline_thread_24h=%s', v_interactions_missing_count)
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
        'orb_20260228_451462cd',
        null,
        now(),
        true,
        false,
        v_subject,
        v_priority,
        v_kind,
        'pipeline-harness',
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

  return jsonb_build_object(
    'ok', true,
    'monitor_name', v_monitor_name,
    'alert_id', v_alert_id,
    'is_alert', v_is_alert,
    'beside_calls_missing_in_interactions_24h', v_beside_missing_count,
    'interactions_missing_in_redline_thread_24h', v_interactions_missing_count,
    'tram_dispatched', v_tram_dispatched,
    'tram_receipt', v_tram_receipt,
    'tram_error', v_tram_error
  );
end;
$$;

comment on function public.run_beside_parity_monitor_v1(integer, boolean, text) is
'Pipeline harness parity monitor: logs Beside->interactions and interactions->redline parity gaps, emits TRAM on threshold breach.';

do $$
begin
  if exists (
    select 1
    from cron.job
    where jobname = 'beside_parity_monitor_v1_15m'
  ) then
    perform cron.unschedule('beside_parity_monitor_v1_15m');
  end if;

  perform cron.schedule(
    'beside_parity_monitor_v1_15m',
    '*/15 * * * *',
    'select public.run_beside_parity_monitor_v1();'
  );
end
$$;
