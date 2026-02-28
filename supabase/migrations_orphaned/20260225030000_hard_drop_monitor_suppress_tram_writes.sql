-- Hard-drop SLA monitor v1.2: suppress TRAM message writes
--
-- Context: Chad directive — SLA alerts are non-issue noise (27+ alerts
-- batch-ACKed). The monitor remains active for observability via
-- monitor_alerts table rows, but TRAM message insertion is removed to
-- stop flooding the TRAM channel.
--
-- Changes to run_hard_drop_sla_monitor():
--   KEPT:   all SELECT/analysis logic (get_hard_drop_sla_monitor call)
--   KEPT:   monitor_alerts INSERT (heartbeat + alert rows)
--   KEPT:   function signature (all parameters preserved for compat)
--   REMOVED: INSERT INTO tram_messages (commented out with explanation)
--   KEPT:   cron job schedule unchanged (hourly at :05)
--
-- Closes INFRA-002.

begin;

create or replace function public.run_hard_drop_sla_monitor(
  p_sla_window_hours integer default 1,
  p_hard_drop_deadline_hours integer default 24,
  p_top_n_clusters integer default 10,
  p_force_breach boolean default false,
  p_emit_tram boolean default true,
  p_actor text default 'system:hard_drop_sla_monitor'
) returns jsonb
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
  v_tram_dispatched boolean := false;
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
    'pending_by_age_bucket',
    coalesce(v_snapshot.pending_by_age_bucket, '{}'::jsonb),
    'top_interaction_clusters',
    coalesce(v_snapshot.top_interaction_clusters, '[]'::jsonb),
    'sla_breach_count', v_effective_breach_count,
    'raw_sla_breach_count', coalesce(v_snapshot.sla_breach_count, 0),
    'forced_breach', coalesce(p_force_breach, false),
    'actor',
    coalesce(
      nullif(trim(p_actor), ''), 'system:hard_drop_sla_monitor'
    ),
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
      v_metric_snapshot || jsonb_build_object(
        'status', 'alert',
        -- v1.2: TRAM writes suppressed per Chad directive (SLA noise, INFRA-002)
        'tram_dispatched', false,
        'tram_suppressed', true,
        'tram_suppressed_reason',
        'v1.2: SLA alerts are noise — monitor-only mode (INFRA-002)'
      ),
      false
    )
    returning id into v_alert_id;

    -- ---------------------------------------------------------------
    -- v1.2 CHANGE: TRAM message insertion REMOVED
    --
    -- Previously this block inserted a row into public.tram_messages
    -- whenever a breach was detected (or forced). This generated 27+
    -- alerts that were batch-ACKed as noise. Per Chad directive the
    -- SLA is a non-issue, so TRAM writes are suppressed while the
    -- monitor continues running for observability via monitor_alerts.
    --
    -- The p_emit_tram parameter is kept in the signature for backward
    -- compatibility but is now a no-op.
    -- ---------------------------------------------------------------
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
    'tram_dispatched', false,
    'tram_suppressed', true,
    'tram_receipt', null,
    'tram_error', null,
    'heartbeat_only', (v_effective_breach_count = 0)
  );
end;
$$;

comment on function public.run_hard_drop_sla_monitor(
  integer, integer, integer, boolean, boolean, text
) is
  'Writes monitor_alerts heartbeat/alert rows hourly. v1.2: TRAM message insertion suppressed (INFRA-002). p_emit_tram kept for compat but is now a no-op.';

-- Cron job is NOT touched — it continues to run hourly at :05 as before.
-- The only change is that breach alerts no longer insert tram_messages rows.

commit;
