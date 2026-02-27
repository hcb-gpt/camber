create or replace view public.v_hard_drop_sla_monitor as
select *
from public.get_hard_drop_sla_monitor();

comment on view public.v_hard_drop_sla_monitor is
  'Single-row hard-drop SLA monitor snapshot: pending_total, pending_by_age_bucket, top_interaction_clusters, sla_breach_count.';

grant select on public.v_hard_drop_sla_monitor to anon, authenticated, service_role;;
