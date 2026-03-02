-- Lock down redline_repair_events with service_role-only access.
-- This table is a durable audit trail for truth-graph repair hooks and should not be client-accessible.

begin;

alter table public.redline_repair_events enable row level security;

drop policy if exists service_role_only on public.redline_repair_events;
create policy service_role_only on public.redline_repair_events
  for all
  to service_role
  using (true)
  with check (true);

-- Defense-in-depth: avoid relying solely on RLS if policies drift.
revoke all on table public.redline_repair_events from anon, authenticated;
grant all on table public.redline_repair_events to service_role;

commit;

