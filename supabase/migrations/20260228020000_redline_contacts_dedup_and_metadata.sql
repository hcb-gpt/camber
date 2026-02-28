-- Migration: redline_contacts dedup and metadata
-- Purpose: 
-- 1) Deduplicate contacts by phone10 to avoid phantom duplicate rows in Redline.
-- 2) Include company, role, and contact_type metadata for better identity display.
-- 3) Provide colliding_contact_ids for interaction merging in thread view.
-- 4) Add is_ambiguous flag for UX awareness.

begin;

-- 1) Improved redline_contacts view with phone10 deduplication and metadata
create or replace view public.redline_contacts as
with raw_stats as (
  select
    c.id as contact_id,
    c.name as contact_name,
    c.phone as contact_phone,
    c.company,
    c.role,
    c.contact_type,
    c.updated_at,
    right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 10) as phone10,
    coalesce(cs.call_count, 0)::integer as call_count,
    coalesce(ss.sms_count, 0)::integer as sms_count,
    coalesce(cls.claim_count, 0)::integer as claim_count,
    coalesce(cls.ungraded_count, 0)::integer as ungraded_count,
    greatest(cs.last_call_at, ss.last_sms_at) as last_activity
  from public.contacts c
  left join (
    select contact_id, count(*) as call_count, max(event_at_utc) as last_call_at
    from public.interactions
    where contact_id is not null
    group by contact_id
  ) cs on cs.contact_id = c.id
  left join (
    select c2.id as contact_id, count(*) as sms_count, max(s.sent_at) as last_sms_at
    from public.sms_messages s
    inner join public.contacts c2 on c2.phone = s.contact_phone
    group by c2.id
  ) ss on ss.contact_id = c.id
  left join (
    select i.contact_id, count(distinct jc.id) as claim_count, count(distinct jc.id) filter (where cg.id is null) as ungraded_count
    from public.interactions i
    inner join public.journal_claims jc on jc.call_id = i.interaction_id
    left join public.claim_grades cg on cg.claim_id = jc.id
    where i.contact_id is not null
    group by i.contact_id
  ) cls on cls.contact_id = c.id
  where (coalesce(cs.call_count, 0) > 0 or coalesce(ss.sms_count, 0) > 0)
    and right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 10) <> ''
),
deduped as (
  select
    phone10,
    -- Pick the contact that was updated most recently
    array_agg(contact_id order by updated_at desc, contact_id) as contact_ids,
    count(*) > 1 as is_ambiguous,
    sum(call_count)::integer as call_count,
    sum(sms_count)::integer as sms_count,
    sum(claim_count)::integer as claim_count,
    sum(ungraded_count)::integer as ungraded_count,
    max(last_activity) as last_activity
  from raw_stats
  group by phone10
)
select
  r.contact_id,
  r.contact_name,
  r.contact_phone,
  r.company,
  r.role,
  r.contact_type,
  d.is_ambiguous,
  d.call_count,
  d.sms_count,
  d.claim_count,
  d.ungraded_count,
  d.last_activity,
  d.contact_ids as colliding_contact_ids
from raw_stats r
inner join deduped d on d.phone10 = r.phone10
where r.contact_id = d.contact_ids[1];

-- 2) Update unified view to include new columns
create or replace view public.redline_contacts_unified as
select
  rc.contact_id,
  rc.contact_name,
  rc.contact_phone,
  rc.company,
  rc.role,
  rc.contact_type,
  rc.is_ambiguous,
  rc.call_count,
  rc.sms_count,
  rc.claim_count,
  rc.ungraded_count,
  rc.last_activity,
  rc.colliding_contact_ids,
  'contacts'::text as source
from public.redline_contacts rc

union all

select
  md5('camber:beside_thread:' || bt.contact_phone_e164)::uuid as contact_id,
  bt.contact_phone_e164 as contact_name,
  bt.contact_phone_e164 as contact_phone,
  null::text as company,
  null::text as role,
  'unknown'::text as contact_type,
  false as is_ambiguous,
  0 as call_count,
  coalesce(sms_agg.sms_count, 0)::integer as sms_count,
  0 as claim_count,
  0 as ungraded_count,
  bt.updated_at_utc as last_activity,
  array[md5('camber:beside_thread:' || bt.contact_phone_e164)::uuid] as colliding_contact_ids,
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

-- 3) Recreate matview with new schema
drop materialized view if exists public.redline_contacts_unified_matview;
create materialized view public.redline_contacts_unified_matview as
select * from public.redline_contacts_unified;

create unique index if not exists redline_contacts_unified_matview_cid_uq
  on public.redline_contacts_unified_matview (contact_id);

create index if not exists redline_contacts_unified_matview_activity_idx
  on public.redline_contacts_unified_matview (last_activity desc nulls last);

commit;
