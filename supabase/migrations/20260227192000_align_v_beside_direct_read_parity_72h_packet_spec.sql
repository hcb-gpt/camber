-- Align Beside parity view to packet spec (v0)
--
-- Requested alignment (report__beside_metrics_packet_format_v0__data3__20260227T1845Z):
-- - occurred_at tolerance = 60s
-- - body normalization + sha256 body_hash
-- - orphan metric excludes events captured <30m ago
-- - source values: zapier | beside_direct_read
--
-- Implementation note:
-- This view compares direct-read events against existing CAMBER tables
-- (sms_messages + calls_raw) which act as the zapier/fallback surface.

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
direct_events as (
  select
    e.beside_event_id,
    e.beside_event_type,
    e.occurred_at_utc,
    e.captured_at_utc,
    e.record_hash,
    e.text,
    e.summary
  from public.beside_thread_events e
  where e.source = 'beside_direct_read'
    and e.beside_event_type in ('message', 'call')
    and e.captured_at_utc >= (select window_start_utc from params)
    and e.captured_at_utc < (select freshness_cutoff_utc from params)
),
direct_norm as (
  select
    de.*,
    lower(
      regexp_replace(
        regexp_replace(trim(coalesce(de.text, de.summary, '')), '\\s+', ' ', 'g'),
        '[^[:alnum:][:space:]]+', '', 'g'
      )
    ) as normalized_body,
    coalesce(
      nullif(de.record_hash, ''),
      encode(
        digest(
          lower(
            regexp_replace(
              regexp_replace(trim(coalesce(de.text, de.summary, '')), '\\s+', ' ', 'g'),
              '[^[:alnum:][:space:]]+', '', 'g'
            )
          ),
          'sha256'
        ),
        'hex'
      )
    ) as body_hash
  from direct_events de
),
msg_match as (
  select
    dn.beside_event_id,
    dn.beside_event_type,
    dn.occurred_at_utc,
    dn.body_hash,
    -- A message is considered matched if:
    -- 1) exact Beside id match exists in sms_messages, OR
    -- 2) there exists an sms_message within +/- 60s whose body_hash matches.
    exists (
      select 1
      from public.sms_messages sm
      where sm.message_id = dn.beside_event_id
    ) as matched_by_id,
    exists (
      select 1
      from public.sms_messages sm
      join params p on true
      where abs(extract(epoch from (sm.sent_at - dn.occurred_at_utc))) <= p.occurred_at_tolerance_seconds
        and encode(
          digest(
            lower(
              regexp_replace(
                regexp_replace(trim(coalesce(sm.content, '')), '\\s+', ' ', 'g'),
                '[^[:alnum:][:space:]]+', '', 'g'
              )
            ),
            'sha256'
          ),
          'hex'
        ) = dn.body_hash
    ) as matched_by_hash_time,
    exists (
      select 1
      from public.sms_messages sm
      join params p on true
      where abs(extract(epoch from (sm.sent_at - dn.occurred_at_utc))) <= p.occurred_at_tolerance_seconds
    ) as occurred_at_match_any
  from direct_norm dn
  where dn.beside_event_type = 'message'
),
call_match as (
  select
    dn.beside_event_id,
    dn.beside_event_type,
    dn.occurred_at_utc,
    null::text as body_hash,
    exists (
      select 1
      from public.calls_raw cr
      where cr.interaction_id = dn.beside_event_id
    ) as matched_by_id,
    false as matched_by_hash_time,
    exists (
      select 1
      from public.calls_raw cr
      join params p on true
      where cr.interaction_id = dn.beside_event_id
        and abs(extract(epoch from (cr.event_at_utc - dn.occurred_at_utc))) <= p.occurred_at_tolerance_seconds
    ) as occurred_at_match_any
  from direct_norm dn
  where dn.beside_event_type = 'call'
),
matched as (
  select * from msg_match
  union all
  select * from call_match
),
agg as (
  select
    m.beside_event_type,
    count(*) as direct_read_total_72h,
    count(*) filter (where (m.matched_by_id or m.matched_by_hash_time)) as matched_total_72h,
    count(*) filter (where not (m.matched_by_id or m.matched_by_hash_time)) as orphan_total_72h,
    avg((m.occurred_at_match_any)::int)::double precision as occurred_at_match_rate,
    case
      when m.beside_event_type = 'message'
        then avg((m.matched_by_hash_time)::int)::double precision
      else 0::double precision
    end as body_hash_match_rate
  from matched m
  group by 1
)
select
  p.as_of_utc,
  p.window_start_utc,
  p.as_of_utc as window_end_utc,
  t.beside_event_type,
  coalesce(a.direct_read_total_72h, 0) as direct_read_total_72h,
  coalesce(a.matched_total_72h, 0) as matched_total_72h,
  coalesce(a.orphan_total_72h, 0) as orphan_total_72h,
  case
    when coalesce(a.direct_read_total_72h, 0) = 0 then 0::double precision
    else coalesce(a.matched_total_72h, 0)::double precision / a.direct_read_total_72h::double precision
  end as match_rate_72h,
  coalesce(a.occurred_at_match_rate, 0) as occurred_at_match_rate,
  coalesce(a.body_hash_match_rate, 0) as body_hash_match_rate,
  p.occurred_at_tolerance_seconds,
  p.freshness_exclusion_minutes
from params p
cross join types t
left join agg a using (beside_event_type)
order by t.beside_event_type;

comment on view public.v_beside_direct_read_parity_72h is
  'Parity metrics (72h) for Beside direct-read vs zapier/fallback surfaces. Orphans exclude events captured <30m. Message matching uses id OR (body_hash + occurred_at within 60s).';

grant select on public.v_beside_direct_read_parity_72h to service_role;

commit;
