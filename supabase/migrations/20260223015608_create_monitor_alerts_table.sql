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

grant select on public.monitor_alerts to service_role;
grant insert, update on public.monitor_alerts to service_role;;
