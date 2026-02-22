-- Create daily call volume view (UTC bucket) from calls_raw.

create or replace view public.v_call_volume_daily as
select
  (date_trunc('day', coalesce(cr.received_at_utc, cr.event_at_utc, cr.ingested_at_utc) at time zone 'UTC'))::date as call_date,
  count(*)::bigint as call_count
from public.calls_raw cr
where coalesce(cr.received_at_utc, cr.event_at_utc, cr.ingested_at_utc) is not null
group by 1;

comment on view public.v_call_volume_daily is
  'Daily call counts from calls_raw using UTC date buckets (received_at_utc fallback event_at_utc fallback ingested_at_utc).';
