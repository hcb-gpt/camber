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

grant execute on function public.run_hard_drop_sla_monitor(integer, integer, integer, boolean, boolean, text) to service_role;;
