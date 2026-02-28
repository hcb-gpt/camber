-- beside_thread_events_parity_proof_v0.sql
-- Read-only proof for source population and parity metrics.

select
  source,
  count(*) as rows
from public.beside_thread_events
where source in ('zapier', 'beside_direct_read')
group by source
order by source;

select
  coalesce(sum(rows), 0) as total_rows_in_scope
from (
  select count(*) as rows
  from public.beside_thread_events
  where source in ('zapier', 'beside_direct_read')
) t;

select *
from public.v_beside_direct_read_parity_72h
order by beside_event_type;
