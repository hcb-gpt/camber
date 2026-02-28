-- P0 FIX: Redline tab bricked — iOS Contact model requires UUID for contact_id.
-- The unified view previously returned NULL for beside_thread rows, breaking decode.
-- Fix: Generate deterministic UUIDs from phone number using md5()::uuid.
-- Same phone always produces the same UUID (stable across matview refreshes).

begin;

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
-- Deterministic UUID from phone: md5('camber:beside_thread:' || phone)::uuid
select
  md5('camber:beside_thread:' || bt.contact_phone_e164)::uuid as contact_id,
  bt.contact_phone_e164 as contact_name,
  bt.contact_phone_e164 as contact_phone,
  0 as call_count,
  coalesce(sms_agg.sms_count, 0)::integer as sms_count,
  0 as claim_count,
  0 as ungraded_count,
  bt.updated_at_utc as last_activity,
  null::text as last_snippet,
  null::text as last_direction,
  'beside_thread'::text as last_interaction_type,
  'beside_thread'::text as source
from public.beside_threads bt
left join lateral (
  select count(*)::integer as sms_count
  from public.sms_messages sm
  where right(regexp_replace(coalesce(sm.contact_phone, ''), '\D', '', 'g'), 10)
      = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
    and right(regexp_replace(coalesce(sm.contact_phone, ''), '\D', '', 'g'), 10) <> ''
) sms_agg on true
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

-- Refresh matview to pick up the new deterministic UUIDs
refresh materialized view concurrently public.redline_contacts_unified_matview;

commit;
