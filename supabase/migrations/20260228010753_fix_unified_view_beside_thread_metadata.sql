-- P0-C FIX: Derive last_snippet/last_direction for beside_thread rows.

create or replace view public.redline_contacts_unified as

-- Part A: All existing redline_contacts rows (backward-compatible)
select
  rc.contact_id,
  rc.contact_name,
  rc.contact_phone,
  rc.call_count,
  rc.sms_count,
  rc.claim_count,
  rc.ungraded_count,
  rc.last_activity,
  rc.last_snippet,
  rc.last_direction,
  rc.last_interaction_type,
  'contacts'::text as source
from public.redline_contacts rc

union all

-- Part B: beside_threads with phones NOT already in redline_contacts
select
  md5('camber:beside_thread:' || bt.contact_phone_e164)::uuid as contact_id,
  coalesce(sms_latest.contact_name_from_sms, bt.contact_phone_e164) as contact_name,
  bt.contact_phone_e164 as contact_phone,
  0 as call_count,
  coalesce(sms_agg.sms_count, 0)::integer as sms_count,
  0 as claim_count,
  0 as ungraded_count,
  coalesce(sms_latest.last_sms_at, bt.updated_at_utc) as last_activity,
  sms_latest.last_snippet,
  sms_latest.last_direction,
  coalesce(sms_latest.last_interaction_type, 'beside_thread')::text as last_interaction_type,
  'beside_thread'::text as source
from public.beside_threads bt
left join lateral (
  select count(*)::integer as sms_count
  from public.sms_messages sm
  where right(regexp_replace(coalesce(sm.contact_phone, ''), '\D', '', 'g'), 10)
      = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
    and right(regexp_replace(coalesce(sm.contact_phone, ''), '\D', '', 'g'), 10) <> ''
) sms_agg on true
left join lateral (
  select
    left(sm2.content, 80) as last_snippet,
    sm2.direction as last_direction,
    'sms'::text as last_interaction_type,
    sm2.sent_at as last_sms_at,
    case
      when sm2.contact_name is not null
        and sm2.contact_name <> ''
        and sm2.contact_name <> bt.contact_phone_e164
      then sm2.contact_name
      else null
    end as contact_name_from_sms
  from public.sms_messages sm2
  where right(regexp_replace(coalesce(sm2.contact_phone, ''), '\D', '', 'g'), 10)
      = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
    and right(regexp_replace(coalesce(sm2.contact_phone, ''), '\D', '', 'g'), 10) <> ''
  order by sm2.sent_at desc nulls last
  limit 1
) sms_latest on true
where bt.contact_phone_e164 is not null
  and not exists (
    select 1
    from public.redline_contacts rc2
    where right(regexp_replace(coalesce(rc2.contact_phone, ''), '\D', '', 'g'), 10)
        = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
      and right(regexp_replace(coalesce(rc2.contact_phone, ''), '\D', '', 'g'), 10) <> ''
  )
  and bt.beside_room_id = (
    select bt2.beside_room_id
    from public.beside_threads bt2
    where bt2.contact_phone_e164 is not null
      and right(regexp_replace(coalesce(bt2.contact_phone_e164, ''), '\D', '', 'g'), 10)
        = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
    order by bt2.updated_at_utc desc nulls last, bt2.beside_room_id
    limit 1
  );

-- Rebuild unique index on contact_id for concurrent refresh
drop index if exists public.redline_contacts_unified_matview_phone_source_uq;
create unique index if not exists redline_contacts_unified_matview_cid_uq
  on public.redline_contacts_unified_matview (contact_id);

-- Refresh matview to pick up the new metadata
refresh materialized view concurrently public.redline_contacts_unified_matview;;
