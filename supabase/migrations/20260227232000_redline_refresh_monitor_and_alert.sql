begin;

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
  v_subject text;
  v_priority text := 'high';
  v_kind text := 'alert';
  v_filename text;
  v_content text;
  v_rows integer := 0;
begin
  select max(created_at) into v_last_journal_claim_at from public.journal_claims;
  select max(materialized_at_utc) into v_last_project_mat_at from public.mat_project_context;
  select max(materialized_at_utc) into v_last_contact_mat_at from public.mat_contact_context;
  select max(materialized_at_utc) into v_last_belief_mat_at from public.mat_belief_context;

  v_journal_stale := v_last_journal_claim_at is null or now() - v_last_journal_claim_at > interval '6 hours';
  v_project_mat_stale := v_last_project_mat_at is null or now() - v_last_project_mat_at > interval '10 minutes';
  v_contact_mat_stale := v_last_contact_mat_at is null or now() - v_last_contact_mat_at > interval '10 minutes';
  v_belief_mat_stale := v_last_belief_mat_at is null or now() - v_last_belief_mat_at > interval '10 minutes';

  v_is_alert := v_journal_stale or v_project_mat_stale or v_contact_mat_stale or v_belief_mat_stale;

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
    'mat_belief_stale', v_belief_mat_stale
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
    v_metric_snapshot || jsonb_build_object('status', case when v_is_alert then 'alert' else 'heartbeat' end),
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
        format('last_mat_belief_context_at=%s', v_last_belief_mat_at)
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
        'orb_20260227_994bbb16',
        null,
        now(),
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
    'tram_error', v_tram_error
  )
  where id = v_alert_id;

  return jsonb_build_object(
    'ok', true,
    'monitor_name', v_monitor_name,
    'alert_id', v_alert_id,
    'is_alert', v_is_alert,
    'journal_stale', v_journal_stale,
    'mat_project_stale', v_project_mat_stale,
    'mat_contact_stale', v_contact_mat_stale,
    'mat_belief_stale', v_belief_mat_stale,
    'tram_dispatched', v_tram_dispatched,
    'tram_receipt', v_tram_receipt,
    'tram_error', v_tram_error
  );
end;
$$;

comment on function public.run_redline_refresh_monitor(boolean, text) is
  'Monitors Redline freshness: alerts when journal_claims is stale >6h or context matviews are stale >10m; can emit TRAM alert to STRAT.';

grant execute on function public.run_redline_refresh_monitor(boolean, text) to service_role;

do $do$
declare
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      select jobid
      into v_job_id
      from cron.job
      where jobname = 'redline_refresh_monitor_10m'
      order by jobid desc
      limit 1;

      if v_job_id is not null then
        perform cron.unschedule(v_job_id);
      end if;

      perform cron.schedule(
        'redline_refresh_monitor_10m',
        '*/10 * * * *',
        $cron$select public.run_redline_refresh_monitor();$cron$
      );
    exception
      when others then
        raise notice 'redline_refresh_monitor_10m cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
