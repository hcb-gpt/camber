-- Upgrade v_call_volume_daily with weekday context, duration, and contact/project reach.

create or replace view public.v_call_volume_daily as
with base as (
  select
    cr.interaction_id,
    coalesce(cr.received_at_utc, cr.event_at_utc, cr.ingested_at_utc) as call_ts_utc,
    case
      when coalesce(cr.raw_snapshot_json ->> 'duration_seconds', cr.raw_snapshot_json ->> 'duration', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
        then (coalesce(cr.raw_snapshot_json ->> 'duration_seconds', cr.raw_snapshot_json ->> 'duration'))::numeric
      else null
    end as duration_seconds,
    coalesce(
      i.contact_id,
      case
        when coalesce(cr.raw_snapshot_json ->> 'contact_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (cr.raw_snapshot_json ->> 'contact_id')::uuid
        else null
      end
    ) as contact_id,
    coalesce(
      i.project_id,
      case
        when coalesce(cr.raw_snapshot_json ->> 'project_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          then (cr.raw_snapshot_json ->> 'project_id')::uuid
        else null
      end
    ) as project_id
  from public.calls_raw cr
  left join public.interactions i on i.interaction_id = cr.interaction_id
  where coalesce(cr.received_at_utc, cr.event_at_utc, cr.ingested_at_utc) is not null
),
daily as (
  select
    date_trunc('day', call_ts_utc at time zone 'UTC')::date as date,
    trim(to_char(date_trunc('day', call_ts_utc at time zone 'UTC')::date, 'Day')) as day_of_week,
    count(*)::bigint as call_count,
    round(avg(duration_seconds)::numeric, 2) as avg_duration_seconds,
    count(distinct contact_id)::bigint as unique_contacts,
    count(distinct project_id)::bigint as unique_projects
  from base
  group by 1, 2
),
scored as (
  select
    d.*,
    avg(d.call_count) over (
      order by d.date
      rows between 7 preceding and 1 preceding
    ) as prev_7day_avg
  from daily d
)
select
  s.date,
  s.day_of_week,
  s.call_count,
  s.avg_duration_seconds,
  s.unique_contacts,
  s.unique_projects,
  case
    when s.prev_7day_avg is null or s.prev_7day_avg = 0 then null
    else round(((s.call_count - s.prev_7day_avg) / s.prev_7day_avg) * 100.0, 2)
  end as vs_7day_avg_pct
from scored s
order by s.date desc;
comment on view public.v_call_volume_daily is
  'Daily call volumes with weekday, average duration, contact/project reach, and percent delta vs prior 7-day average.';
