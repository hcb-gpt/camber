begin;

create or replace function public.cleanup_redline_refresh_monitor_alerts(
  p_actor text default 'system:redline_refresh_monitor',
  p_ttl interval default interval '2 hours'
)
returns table (
  deferred_tram_count integer,
  ttl_backfilled_tram_count integer,
  acked_monitor_count integer,
  active_tram_receipt text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor text := coalesce(nullif(trim(p_actor), ''), 'system:redline_refresh_monitor');
  v_now timestamptz := now();
begin
  deferred_tram_count := 0;
  ttl_backfilled_tram_count := 0;
  acked_monitor_count := 0;
  active_tram_receipt := null;

  if exists (
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = 'tram_messages'
  ) then
    with ranked_open as (
      select
        receipt,
        created_at,
        row_number() over (
          order by created_at desc, coalesce(message_seq, 0) desc, receipt desc
        ) as rn
      from public.tram_messages
      where subject = 'alert__redline_refresh_monitor_v1'
        and resolution is null
    ),
    resolved as (
      update public.tram_messages t
      set
        resolution = 'DEFERRED',
        expires_at = coalesce(t.expires_at, t.created_at + p_ttl)
      from ranked_open r
      where t.receipt = r.receipt
        and (
          r.rn > 1
          or t.created_at < v_now - p_ttl
        )
      returning 1
    )
    select count(*)::integer
    into deferred_tram_count
    from resolved;

    update public.tram_messages
    set expires_at = created_at + p_ttl
    where subject = 'alert__redline_refresh_monitor_v1'
      and resolution is null
      and expires_at is null;

    get diagnostics ttl_backfilled_tram_count = row_count;

    select t.receipt
    into active_tram_receipt
    from public.tram_messages t
    where t.subject = 'alert__redline_refresh_monitor_v1'
      and t.resolution is null
      and coalesce(t.expires_at, t.created_at + p_ttl) > v_now
    order by t.created_at desc, coalesce(t.message_seq, 0) desc, t.receipt desc
    limit 1;
  end if;

  with ranked_monitor as (
    select
      id,
      fired_at,
      row_number() over (order by fired_at desc, id desc) as rn
    from public.monitor_alerts
    where monitor_name = 'redline_refresh_monitor_v1'
      and acked = false
  ),
  acked_rows as (
    update public.monitor_alerts m
    set
      acked = true,
      metric_snapshot = coalesce(m.metric_snapshot, '{}'::jsonb) || jsonb_build_object(
        'cleanup_reason', 'ttl_or_duplicate',
        'cleanup_at_utc', v_now,
        'cleanup_actor', v_actor,
        'ttl_hours', round(extract(epoch from p_ttl) / 3600.0, 3)
      )
    from ranked_monitor r
    where m.id = r.id
      and (
        r.rn > 1
        or m.fired_at < v_now - p_ttl
      )
    returning 1
  )
  select count(*)::integer
  into acked_monitor_count
  from acked_rows;

  return query
  select
    deferred_tram_count,
    ttl_backfilled_tram_count,
    acked_monitor_count,
    active_tram_receipt;
end;
$$;

comment on function public.cleanup_redline_refresh_monitor_alerts(text, interval) is
  'Dedupes recurring redline refresh alerts, backfills a TTL on the active alert, and resolves stale duplicates.';

grant execute on function public.cleanup_redline_refresh_monitor_alerts(text, interval) to service_role;

create or replace function public.run_redline_refresh_monitor(
  p_emit_tram boolean default true,
  p_actor text default 'system:redline_refresh_monitor'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_monitor_name text := 'redline_refresh_monitor_v1';
  v_alert_ttl interval := interval '2 hours';
  v_last_journal_claim_at timestamptz;
  v_last_project_mat_at timestamptz;
  v_last_contact_mat_at timestamptz;
  v_last_belief_mat_at timestamptz;
  v_journal_stale boolean := false;
  v_project_mat_stale boolean := false;
  v_contact_mat_stale boolean := false;
  v_belief_mat_stale boolean := false;
  v_is_alert boolean := false;
  v_metric_snapshot jsonb := '{}'::jsonb;
  v_alert_id uuid;
  v_tram_receipt text;
  v_tram_dispatched boolean := false;
  v_tram_error text;
  v_tram_suppressed boolean := false;
  v_tram_suppression_reason text;
  v_subject text;
  v_priority text := 'high';
  v_kind text := 'alert';
  v_filename text;
  v_content text;
  v_rows integer := 0;
  v_monitor_status text := 'heartbeat';
  v_tram_expires_at timestamptz;
  v_tram_table_exists boolean := false;
  v_cleanup_deferred_tram_count integer := 0;
  v_cleanup_ttl_backfilled_tram_count integer := 0;
  v_cleanup_acked_monitor_count integer := 0;
  v_active_tram_receipt text;
begin
  select
    c.deferred_tram_count,
    c.ttl_backfilled_tram_count,
    c.acked_monitor_count,
    c.active_tram_receipt
  into
    v_cleanup_deferred_tram_count,
    v_cleanup_ttl_backfilled_tram_count,
    v_cleanup_acked_monitor_count,
    v_active_tram_receipt
  from public.cleanup_redline_refresh_monitor_alerts(p_actor, v_alert_ttl) c;

  select max(created_at) into v_last_journal_claim_at from public.journal_claims;
  select max(materialized_at_utc) into v_last_project_mat_at from public.mat_project_context;
  select max(materialized_at_utc) into v_last_contact_mat_at from public.mat_contact_context;
  select max(materialized_at_utc) into v_last_belief_mat_at from public.mat_belief_context;

  v_journal_stale := v_last_journal_claim_at is null or now() - v_last_journal_claim_at > interval '6 hours';
  v_project_mat_stale := v_last_project_mat_at is null or now() - v_last_project_mat_at > interval '10 minutes';
  v_contact_mat_stale := v_last_contact_mat_at is null or now() - v_last_contact_mat_at > interval '10 minutes';
  v_belief_mat_stale := v_last_belief_mat_at is null or now() - v_last_belief_mat_at > interval '10 minutes';

  v_is_alert := v_journal_stale or v_project_mat_stale or v_contact_mat_stale or v_belief_mat_stale;

  v_tram_table_exists := exists (
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = 'tram_messages'
  );

  if v_is_alert and coalesce(p_emit_tram, true) and v_tram_table_exists and v_active_tram_receipt is not null then
    v_tram_suppressed := true;
    v_tram_suppression_reason := format(
      'active_alert_exists:%s',
      v_active_tram_receipt
    );
  end if;

  v_monitor_status := case
    when not v_is_alert then 'heartbeat'
    when v_tram_suppressed then 'alert_suppressed'
    when coalesce(p_emit_tram, true) and v_tram_table_exists then 'alert'
    else 'alert_observed'
  end;

  v_metric_snapshot := jsonb_build_object(
    'monitor_name', v_monitor_name,
    'checked_at_utc', now(),
    'actor', coalesce(nullif(trim(p_actor), ''), 'system:redline_refresh_monitor'),
    'last_journal_claim_at', v_last_journal_claim_at,
    'journal_claim_age_minutes', case when v_last_journal_claim_at is null then null else round(extract(epoch from (now() - v_last_journal_claim_at))/60.0, 3) end,
    'last_mat_project_context_at', v_last_project_mat_at,
    'last_mat_contact_context_at', v_last_contact_mat_at,
    'last_mat_belief_context_at', v_last_belief_mat_at,
    'mat_project_age_minutes', case when v_last_project_mat_at is null then null else round(extract(epoch from (now() - v_last_project_mat_at))/60.0, 3) end,
    'mat_contact_age_minutes', case when v_last_contact_mat_at is null then null else round(extract(epoch from (now() - v_last_contact_mat_at))/60.0, 3) end,
    'mat_belief_age_minutes', case when v_last_belief_mat_at is null then null else round(extract(epoch from (now() - v_last_belief_mat_at))/60.0, 3) end,
    'journal_stale', v_journal_stale,
    'mat_project_stale', v_project_mat_stale,
    'mat_contact_stale', v_contact_mat_stale,
    'mat_belief_stale', v_belief_mat_stale,
    'status', v_monitor_status,
    'tram_ttl_hours', round(extract(epoch from v_alert_ttl) / 3600.0, 3),
    'active_tram_receipt', v_active_tram_receipt,
    'tram_suppressed', v_tram_suppressed,
    'tram_suppression_reason', v_tram_suppression_reason,
    'cleanup_deferred_tram_count', v_cleanup_deferred_tram_count,
    'cleanup_ttl_backfilled_tram_count', v_cleanup_ttl_backfilled_tram_count,
    'cleanup_acked_monitor_count', v_cleanup_acked_monitor_count
  );

  insert into public.monitor_alerts (
    monitor_name,
    fired_at,
    metric_snapshot,
    acked
  )
  values (
    v_monitor_name,
    now(),
    v_metric_snapshot,
    v_monitor_status <> 'alert'
  )
  returning id into v_alert_id;

  if v_is_alert
     and coalesce(p_emit_tram, true)
     and v_tram_table_exists
     and not v_tram_suppressed then
    begin
      v_tram_receipt := format(
        'alert__redline_refresh_monitor_v1__%s',
        substr(md5(clock_timestamp()::text || random()::text), 1, 12)
      );
      v_subject := 'alert__redline_refresh_monitor_v1';
      v_filename := format(
        '%s__to_strat__from_data__prio_%s__kind_%s__thread_redline__%s.md',
        to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"'),
        v_priority,
        v_kind,
        v_subject
      );
      v_tram_expires_at := now() + v_alert_ttl;
      v_content := concat_ws(
        E'\n',
        'redline_refresh_monitor_v1 threshold breached',
        format('monitor_alert_id=%s', v_alert_id),
        format('journal_stale=%s', v_journal_stale),
        format('mat_project_stale=%s', v_project_mat_stale),
        format('mat_contact_stale=%s', v_contact_mat_stale),
        format('mat_belief_stale=%s', v_belief_mat_stale),
        format('last_journal_claim_at=%s', v_last_journal_claim_at),
        format('last_mat_project_context_at=%s', v_last_project_mat_at),
        format('last_mat_contact_context_at=%s', v_last_contact_mat_at),
        format('last_mat_belief_context_at=%s', v_last_belief_mat_at),
        format('ttl_hours=%s', round(extract(epoch from v_alert_ttl) / 3600.0, 3))
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
        expires_at,
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
        'orb_20260227_994bbb16',
        null,
        now(),
        v_tram_expires_at,
        true,
        false,
        v_subject,
        v_priority,
        v_kind,
        'redline',
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
    'tram_error', v_tram_error,
    'tram_expires_at', v_tram_expires_at
  )
  where id = v_alert_id;

  return jsonb_build_object(
    'ok', true,
    'monitor_name', v_monitor_name,
    'alert_id', v_alert_id,
    'status', v_monitor_status,
    'is_alert', v_is_alert,
    'journal_stale', v_journal_stale,
    'mat_project_stale', v_project_mat_stale,
    'mat_contact_stale', v_contact_mat_stale,
    'mat_belief_stale', v_belief_mat_stale,
    'tram_dispatched', v_tram_dispatched,
    'tram_receipt', v_tram_receipt,
    'tram_error', v_tram_error,
    'tram_expires_at', v_tram_expires_at,
    'tram_suppressed', v_tram_suppressed,
    'tram_suppression_reason', v_tram_suppression_reason,
    'active_tram_receipt', v_active_tram_receipt,
    'cleanup_deferred_tram_count', v_cleanup_deferred_tram_count,
    'cleanup_ttl_backfilled_tram_count', v_cleanup_ttl_backfilled_tram_count,
    'cleanup_acked_monitor_count', v_cleanup_acked_monitor_count
  );
end;
$$;

comment on function public.run_redline_refresh_monitor(boolean, text) is
  'Monitors Redline freshness: alerts when journal_claims is stale >6h or context matviews are stale >10m; keeps one active STRAT alert with a 2h TTL and auto-defers stale duplicates.';

grant execute on function public.run_redline_refresh_monitor(boolean, text) to service_role;

select *
from public.cleanup_redline_refresh_monitor_alerts(
  'migration:20260312143000_redline_refresh_monitor_ttl_circuit_breaker',
  interval '2 hours'
);

commit;
