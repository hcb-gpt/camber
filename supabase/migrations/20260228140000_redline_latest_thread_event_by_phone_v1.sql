-- Add RPC helper for Redline contacts instrumentation.
-- Purpose: Attach `last_interaction_id` (and related fields) to contacts payload
-- without changing existing views/matviews.

begin;

create or replace function public.redline_latest_thread_event_by_phone_v1(phone_list text[])
returns table (
  contact_phone text,
  interaction_id text,
  interaction_type text,
  direction text,
  event_at_utc timestamptz,
  summary text
) language sql stable as $$
  select distinct on (rt.contact_phone)
    rt.contact_phone,
    rt.interaction_id,
    rt.interaction_type,
    rt.direction,
    rt.event_at_utc,
    rt.summary
  from public.redline_thread rt
  where rt.contact_phone = any(phone_list)
  order by rt.contact_phone, rt.event_at_utc desc nulls last;
$$;

grant execute on function public.redline_latest_thread_event_by_phone_v1(text[]) to service_role;

commit;

