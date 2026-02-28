-- Rework Beside parity view to VP acceptance fields + packet spec
--
-- Requirements (action_item__revise_beside_parity_view_to_vp_fields__data1__20260227T1906Z):
-- - Pair direct-read vs zapier by comparison_key:
--     coalesce(zapier_event_id, beside_event_id, camber_interaction_id)
-- - Compute match booleans and aggregated rates for:
--     contact_id, project_id, interaction_type, occurred_at within 60s, body_hash
-- - Orphan metric excludes events captured <30m ago
-- - Body normalization + sha256
--
-- Note:
-- - This view assumes BOTH sources may be written into public.beside_thread_events
--   with source in ('beside_direct_read','zapier').

begin;

create extension if not exists pgcrypto;

create or replace view public.v_beside_direct_read_parity_72h as
with params as (
  select
    now() as as_of_utc,
    now() - interval '72 hours' as window_start_utc,
    now() - interval '30 minutes' as freshness_cutoff_utc,
    60::int as occurred_at_tolerance_seconds,
    30::int as freshness_exclusion_minutes
),
types as (
  select 'call'::text as beside_event_type
  union all
  select 'message'::text as beside_event_type
),
base_events as (
  select
    coalesce(nullif(e.zapier_event_id, ''), e.beside_event_id, e.camber_interaction_id) as comparison_key,
    e.source,
    e.beside_event_type,
    e.occurred_at_utc,
    e.captured_at_utc,
    coalesce(e.contact_id, i.contact_id) as contact_id,
    coalesce(i.project_id, null) as project_id,
    coalesce(i.channel, e.beside_event_type) as interaction_type,
    lower(
      regexp_replace(
        regexp_replace(
          trim(
            coalesce(
              e.text,
              e.summary,
              case when e.payload_json is not null then e.payload_json::text else null end,
              ''
            )
          ),
          '\\s+',
          ' ',
          'g'
        ),
        '[^[:alnum:][:space:]]+',
        '',
        'g'
      )
    ) as normalized_body,
    coalesce(
      nullif(e.record_hash, ''),
      encode(
        digest(
          lower(
            regexp_replace(
              regexp_replace(
                trim(
                  coalesce(
                    e.text,
                    e.summary,
                    case when e.payload_json is not null then e.payload_json::text else null end,
                    ''
                  )
                ),
                '\\s+',
                ' ',
                'g'
              ),
              '[^[:alnum:][:space:]]+',
              '',
              'g'
            )
          ),
          'sha256'
        ),
        'hex'
      )
    ) as body_hash
  from public.beside_thread_events e
  left join public.interactions i
    on i.interaction_id = e.camber_interaction_id
  where e.source in ('beside_direct_read', 'zapier')
    and e.beside_event_type in ('message', 'call')
    and e.captured_at_utc >= (select window_start_utc from params)
    and e.captured_at_utc < (select freshness_cutoff_utc from params)
),
dedup as (
  -- Keep the latest row per source/comparison_key/type to avoid multiplicative joins.
  select *
  from (
    select
      be.*,
      row_number() over (
        partition by be.source, be.comparison_key, be.beside_event_type
        order by be.captured_at_utc desc
      ) as rn
    from base_events be
    where be.comparison_key is not null and be.comparison_key <> ''
  ) x
  where x.rn = 1
),
direct_rows as (
  select *
  from dedup
  where source = 'beside_direct_read'
),
zapier_rows as (
  select *
  from dedup
  where source = 'zapier'
),
paired as (
  select
    d.beside_event_type,
    d.comparison_key,
    d.contact_id as direct_contact_id,
    z.contact_id as zapier_contact_id,
    d.project_id as direct_project_id,
    z.project_id as zapier_project_id,
    d.interaction_type as direct_interaction_type,
    z.interaction_type as zapier_interaction_type,
    d.occurred_at_utc as direct_occurred_at,
    z.occurred_at_utc as zapier_occurred_at,
    d.body_hash as direct_body_hash,
    z.body_hash as zapier_body_hash
  from direct_rows d
  join zapier_rows z
    on z.comparison_key = d.comparison_key
   and z.beside_event_type = d.beside_event_type
),
match_flags as (
  select
    p.beside_event_type,
    (p.direct_contact_id is not distinct from p.zapier_contact_id) as contact_match,
    (p.direct_project_id is not distinct from p.zapier_project_id) as project_match,
    (p.direct_interaction_type is not distinct from p.zapier_interaction_type) as interaction_type_match,
    (abs(extract(epoch from (p.direct_occurred_at - p.zapier_occurred_at))) <= (select occurred_at_tolerance_seconds from params)) as occurred_at_match,
    (p.direct_body_hash is not distinct from p.zapier_body_hash) as body_hash_match
  from paired p
),
agg_pairs as (
  select
    mf.beside_event_type,
    count(*) as compared_pairs,
    sum((mf.contact_match and mf.project_match and mf.interaction_type_match and mf.occurred_at_match and mf.body_hash_match)::int) as full_match_pairs,
    avg(mf.contact_match::int)::double precision as contact_match_rate,
    avg(mf.project_match::int)::double precision as project_match_rate,
    avg(mf.interaction_type_match::int)::double precision as interaction_type_match_rate,
    avg(mf.occurred_at_match::int)::double precision as occurred_at_match_rate,
    avg(mf.body_hash_match::int)::double precision as body_hash_match_rate
  from match_flags mf
  group by 1
),
agg_direct as (
  select
    dr.beside_event_type,
    count(*) as direct_read_total_72h
  from direct_rows dr
  group by 1
)
select
  -- Keep original columns stable (order) to allow CREATE OR REPLACE
  t.beside_event_type,
  coalesce(ad.direct_read_total_72h, 0) as direct_read_total_72h,
  coalesce(ap.compared_pairs, 0) as matched_total_72h,
  greatest(coalesce(ad.direct_read_total_72h, 0) - coalesce(ap.compared_pairs, 0), 0) as orphan_total_72h,
  case
    when coalesce(ap.compared_pairs, 0) = 0 then 0::double precision
    else coalesce(ap.full_match_pairs, 0)::double precision / ap.compared_pairs::double precision
  end as match_rate_72h,
  coalesce(ap.occurred_at_match_rate, 0) as occurred_at_match_rate,
  coalesce(ap.body_hash_match_rate, 0) as body_hash_match_rate,
  (select occurred_at_tolerance_seconds from params) as occurred_at_tolerance_seconds,
  (select freshness_exclusion_minutes from params) as freshness_exclusion_minutes,
  -- appended previously
  (select as_of_utc from params) as as_of_utc,
  (select window_start_utc from params) as window_start_utc,
  (select as_of_utc from params) as window_end_utc,
  -- new VP fields appended
  coalesce(ap.compared_pairs, 0) as compared_pairs,
  coalesce(ap.full_match_pairs, 0) as full_match_pairs,
  coalesce(ap.contact_match_rate, 0) as contact_match_rate,
  coalesce(ap.project_match_rate, 0) as project_match_rate,
  coalesce(ap.interaction_type_match_rate, 0) as interaction_type_match_rate
from types t
left join agg_pairs ap using (beside_event_type)
left join agg_direct ad using (beside_event_type)
order by t.beside_event_type;

comment on view public.v_beside_direct_read_parity_72h is
  'VP parity view (72h) pairing beside_direct_read vs zapier by comparison_key; full match requires contact_id/project_id/interaction_type/occurred_at<=60s/body_hash match; denominator excludes events captured <30m ago.';

grant select on public.v_beside_direct_read_parity_72h to service_role;

commit;
