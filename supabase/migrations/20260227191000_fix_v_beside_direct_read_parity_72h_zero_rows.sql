-- Patch: ensure parity view always returns both message + call rows (0s when no data)

begin;

create or replace view public.v_beside_direct_read_parity_72h as
with types as (
  select 'message'::text as beside_event_type
  union all
  select 'call'::text as beside_event_type
),
direct_events as (
  select
    bte.beside_event_id,
    bte.beside_event_type,
    bte.occurred_at_utc
  from public.beside_thread_events bte
  where bte.source = 'beside_direct_read'
    and bte.beside_event_type in ('message', 'call')
    and bte.occurred_at_utc >= (now() - interval '72 hours')
),
matched as (
  select
    de.beside_event_id,
    de.beside_event_type,
    de.occurred_at_utc,
    case
      when de.beside_event_type = 'message'
        then exists (
          select 1
          from public.sms_messages sm
          where sm.message_id = de.beside_event_id
        )
      when de.beside_event_type = 'call'
        then exists (
          select 1
          from public.calls_raw cr
          where cr.interaction_id = de.beside_event_id
        )
      else false
    end as is_matched
  from direct_events de
),
agg as (
  select
    m.beside_event_type,
    count(*) as direct_read_total_72h,
    count(*) filter (where m.is_matched) as matched_total_72h,
    count(*) filter (where not m.is_matched) as orphan_total_72h
  from matched m
  group by 1
)
select
  t.beside_event_type,
  coalesce(a.direct_read_total_72h, 0) as direct_read_total_72h,
  coalesce(a.matched_total_72h, 0) as matched_total_72h,
  coalesce(a.orphan_total_72h, 0) as orphan_total_72h,
  case
    when coalesce(a.direct_read_total_72h, 0) = 0 then 0::double precision
    else coalesce(a.matched_total_72h, 0)::double precision / a.direct_read_total_72h::double precision
  end as match_rate_72h
from types t
left join agg a using (beside_event_type)
order by 1;

grant select on public.v_beside_direct_read_parity_72h to service_role;

commit;
