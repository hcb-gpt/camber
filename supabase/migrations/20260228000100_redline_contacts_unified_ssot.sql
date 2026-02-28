-- Redline Contacts Unified SSOT View
--
-- Purpose: Create a single view that includes ALL contacts visible in the
-- existing redline_contacts view PLUS beside_threads rows that have phones
-- but no matching contact record. This closes the 65% visibility gap where
-- 114 of 174 phone-bearing beside_threads were invisible to Redline.
--
-- Approach: UNION ALL the existing view with a beside_threads-only query,
-- using a LEFT JOIN anti-pattern to exclude threads already represented.
-- Adds a `source` discriminator column ('contacts' | 'beside_thread').

begin;

-- 1) Unified view: existing redline_contacts + orphaned beside_threads
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
-- Join key: RIGHT(phone, 10) digits matching, same as contact_lookup CTE
select
  null::uuid as contact_id,
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
  -- Exclude threads whose phone already appears in redline_contacts
  and not exists (
    select 1
    from public.redline_contacts rc2
    where right(regexp_replace(coalesce(rc2.contact_phone, ''), '\D', '', 'g'), 10)
        = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
      and right(regexp_replace(coalesce(rc2.contact_phone, ''), '\D', '', 'g'), 10) <> ''
  )
  -- Deduplicate beside_threads with same phone (pick one per phone10)
  and bt.beside_room_id = (
    select bt2.beside_room_id
    from public.beside_threads bt2
    where bt2.contact_phone_e164 is not null
      and right(regexp_replace(coalesce(bt2.contact_phone_e164, ''), '\D', '', 'g'), 10)
        = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
    order by bt2.updated_at_utc desc nulls last, bt2.beside_room_id
    limit 1
  );

-- 2) Materialized view for fast reads from edge functions
create materialized view public.redline_contacts_unified_matview as
select * from public.redline_contacts_unified;

-- Unique index required for REFRESH CONCURRENTLY.
-- contact_id is NULL for beside_thread rows, so we need a composite key.
-- Use contact_phone + source as the unique key since every row has a phone.
create unique index redline_contacts_unified_matview_phone_source_uq
  on public.redline_contacts_unified_matview (
    coalesce(contact_phone, ''),
    source
  );

-- Additional index for ordering by last_activity (hot path)
create index redline_contacts_unified_matview_activity_idx
  on public.redline_contacts_unified_matview (last_activity desc nulls last);

-- 3) Grants
grant select on public.redline_contacts_unified to service_role;
grant select on public.redline_contacts_unified_matview to service_role;

-- 4) pg_cron refresh (same pattern as existing matview)
do $do$
declare
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      select jobid
      into v_job_id
      from cron.job
      where jobname = 'refresh_redline_contacts_unified_matview_1m'
      order by jobid desc
      limit 1;

      if v_job_id is not null then
        perform cron.unschedule(v_job_id);
      end if;

      perform cron.schedule(
        'refresh_redline_contacts_unified_matview_1m',
        '*/1 * * * *',
        $$refresh materialized view concurrently public.redline_contacts_unified_matview;$$
      );
    exception
      when others then
        raise notice 'refresh_redline_contacts_unified_matview_1m cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
