-- Create v_contact_activity_summary ("Who's been talking")
-- Source surfaces: calls_raw + contacts + attribution mapping from interactions/raw_snapshot_json.

create or replace view public.v_contact_activity_summary as
with calls_enriched as (
  select
    cr.id as call_id,
    coalesce(cr.event_at_utc, cr.ingested_at_utc) as call_ts,
    case
      when coalesce(cr.raw_snapshot_json->>'contact_id', '') ~* '^[0-9a-f-]{36}$'
        then (cr.raw_snapshot_json->>'contact_id')::uuid
      else null
    end as contact_id_from_snapshot,
    i.contact_id as contact_id_from_interactions,
    c_phone.id as contact_id_from_phone,
    i.project_id as project_id_from_interactions,
    case
      when coalesce(cr.raw_snapshot_json->>'candidate_project_id', '') ~* '^[0-9a-f-]{36}$'
        then (cr.raw_snapshot_json->>'candidate_project_id')::uuid
      else null
    end as project_id_from_snapshot,
    coalesce(
      nullif(regexp_replace(coalesce(cr.raw_snapshot_json->>'duration_seconds', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      nullif(regexp_replace(coalesce(cr.raw_snapshot_json->>'duration', ''), '[^0-9.-]', '', 'g'), '')::numeric,
      null::numeric
    ) as call_duration_seconds
  from public.calls_raw cr
  left join public.interactions i
    on i.interaction_id = cr.interaction_id
  left join public.contacts c_phone
    on c_phone.phone = cr.other_party_phone
    or c_phone.secondary_phone = cr.other_party_phone
),
calls_resolved as (
  select
    ce.call_id,
    ce.call_ts,
    coalesce(ce.contact_id_from_snapshot, ce.contact_id_from_interactions, ce.contact_id_from_phone) as contact_id,
    ce.call_duration_seconds,
    ce.project_id_from_interactions,
    ce.project_id_from_snapshot
  from calls_enriched ce
),
contact_rollup as (
  select
    cr.contact_id,
    count(*) filter (where cr.call_ts >= (now() at time zone 'utc' - interval '7 days'))::bigint as call_count_7d,
    count(*) filter (where cr.call_ts >= (now() at time zone 'utc' - interval '30 days'))::bigint as call_count_30d,
    max(cr.call_ts) as last_call_date,
    avg(cr.call_duration_seconds) as avg_call_duration
  from calls_resolved cr
  where cr.contact_id is not null
  group by cr.contact_id
),
contact_projects as (
  select
    cr.contact_id,
    array_remove(array_agg(distinct p.name), null) as projects_referenced
  from calls_resolved cr
  left join public.projects p
    on p.id = coalesce(cr.project_id_from_interactions, cr.project_id_from_snapshot)
  where cr.contact_id is not null
  group by cr.contact_id
)
select
  c.id as contact_id,
  c.name as contact_name,
  c.company,
  coalesce(r.call_count_7d, 0)::bigint as call_count_7d,
  coalesce(r.call_count_30d, 0)::bigint as call_count_30d,
  r.last_call_date,
  coalesce(cp.projects_referenced, array[]::text[]) as projects_referenced,
  round(coalesce(r.avg_call_duration, 0), 2) as avg_call_duration,
  (
    coalesce(c.contact_type, '') in ('vendor', 'subcontractor', 'trade')
    or c.trade is not null
  ) as is_subcontractor,
  (coalesce(c.contact_type, '') in ('client', 'homeowner')) as is_client
from public.contacts c
left join contact_rollup r
  on r.contact_id = c.id
left join contact_projects cp
  on cp.contact_id = c.id
where coalesce(r.call_count_30d, 0) > 0;
comment on view public.v_contact_activity_summary is
  'Contact activity summary from calls_raw + contacts with interaction/raw-snapshot project attribution references.';
