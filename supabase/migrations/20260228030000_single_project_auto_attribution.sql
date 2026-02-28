-- Migration: Single-project auto-attribution (v2)
-- Purpose: 
-- 1) Add client_name matching to anchored project detection.
-- 2) Deterministically auto-attribute for anchored contacts.
-- 3) Fix badge count in redline_contacts view.

begin;

-- 1) Helper to find the single project for a contact
create or replace function public.get_contact_anchored_project_id(p_contact_id uuid)
returns uuid
language sql
stable
as $$
  with candidates as (
    -- Source 1: Explicit project_contacts link (SSOT)
    select project_id from public.project_contacts where contact_id = p_contact_id and is_active = true
    union
    -- Source 2: Client name match (Authoritative for Homeowners)
    select p.id as project_id
    from public.projects p
    join public.contacts c on c.name = p.client_name
    where c.id = p_contact_id
  )
  select project_id
  from candidates
  group by project_id
  having (select count(distinct project_id) from candidates) = 1;
$$;

-- 2) Auto-assign project on interactions
create or replace function public.trg_auto_assign_interaction_project_fn()
returns trigger
language plpgsql
as $$
declare
  v_anchored_project_id uuid;
begin
  if NEW.project_id is null and NEW.contact_id is not null then
    v_anchored_project_id := public.get_contact_anchored_project_id(NEW.contact_id);
    if v_anchored_project_id is not null then
      NEW.project_id := v_anchored_project_id;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_auto_assign_interaction_project on public.interactions;
create trigger trg_auto_assign_interaction_project
  before insert or update of contact_id, project_id
  on public.interactions
  for each row
  execute function public.trg_auto_assign_interaction_project_fn();

-- 3) Auto-assign project on span_attributions
create or replace function public.trg_auto_assign_span_project_fn()
returns trigger
language plpgsql
as $$
declare
  v_contact_id uuid;
  v_anchored_project_id uuid;
begin
  if NEW.applied_project_id is null and NEW.span_id is not null then
    select i.contact_id into v_contact_id
    from public.conversation_spans s
    join public.interactions i on i.interaction_id = s.interaction_id
    where s.id = NEW.span_id;

    if v_contact_id is not null then
      v_anchored_project_id := public.get_contact_anchored_project_id(v_contact_id);
      if v_anchored_project_id is not null then
        NEW.applied_project_id := v_anchored_project_id;
        NEW.needs_review := false;
        NEW.reasoning := coalesce(NEW.reasoning || ' ', '') || '(Auto-attributed: single-project contact)';
        NEW.decision := 'assign';
        NEW.confidence := 1.0;
        NEW.attribution_source := 'anchored_contact';
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_auto_assign_span_project on public.span_attributions;
create trigger trg_auto_assign_span_project
  before insert or update of applied_project_id, span_id
  on public.span_attributions
  for each row
  execute function public.trg_auto_assign_span_project_fn();

-- 4) Update redline_contacts view
drop view if exists public.redline_contacts cascade;
drop view if exists public.redline_contacts_unified cascade;

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
    coalesce(pa.pending_count, 0)::integer as pending_attribution_count,
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
  left join (
    select i.contact_id, count(*) as pending_count
    from public.interactions i
    join public.conversation_spans s on s.interaction_id = i.interaction_id
    join public.span_attributions sa on sa.span_id = s.id
    where sa.needs_review = true
    group by i.contact_id
  ) pa on pa.contact_id = c.id
  where (coalesce(cs.call_count, 0) > 0 or coalesce(ss.sms_count, 0) > 0)
    and right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 10) <> ''
),
deduped as (
  select
    phone10,
    array_agg(contact_id order by updated_at desc, contact_id) as contact_ids,
    count(*) > 1 as is_ambiguous,
    sum(call_count)::integer as call_count,
    sum(sms_count)::integer as sms_count,
    sum(claim_count)::integer as claim_count,
    sum(ungraded_count)::integer as ungraded_count,
    sum(pending_attribution_count)::integer as pending_attribution_count,
    max(last_activity) as last_activity
  from raw_stats
  group by phone10
),
last_call as (
  select distinct on (i.contact_id)
    i.contact_id,
    left(i.human_summary, 80) as snippet,
    cr.direction,
    'call'::text as interaction_type,
    i.event_at_utc
  from public.interactions i
  left join public.calls_raw cr on cr.interaction_id = i.interaction_id
  where i.contact_id is not null
  order by i.contact_id, i.event_at_utc desc
),
last_sms as (
  select distinct on (c.id)
    c.id as contact_id,
    left(s.content, 80) as snippet,
    s.direction,
    'sms'::text as interaction_type,
    s.sent_at as event_at_utc
  from public.sms_messages s
  inner join public.contacts c on c.phone = s.contact_phone
  order by c.id, s.sent_at desc
),
latest_activity as (
  select distinct on (contact_id)
    contact_id,
    snippet,
    direction,
    interaction_type
  from (
    select * from last_call
    union all
    select * from last_sms
  ) combined
  order by contact_id, event_at_utc desc
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
  (d.ungraded_count + d.pending_attribution_count)::integer as ungraded_count,
  d.last_activity,
  la.snippet as last_snippet,
  la.direction as last_direction,
  la.interaction_type as last_interaction_type,
  d.contact_ids as colliding_contact_ids
from raw_stats r
inner join deduped d on d.phone10 = r.phone10
left join latest_activity la on la.contact_id = r.contact_id
where r.contact_id = d.contact_ids[1];

-- Recreate unified view
create or replace view public.redline_contacts_unified as
select
  rc.*,
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
  last_msg.content as last_snippet,
  coalesce(last_msg.direction, 'inbound') as last_direction,
  'beside_thread'::text as last_interaction_type,
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
left join lateral (
  select sm2.direction, sm2.content
  from public.sms_messages sm2
  where right(regexp_replace(coalesce(sm2.contact_phone, ''), '\D', '', 'g'), 10)
      = right(regexp_replace(coalesce(bt.contact_phone_e164, ''), '\D', '', 'g'), 10)
    and right(regexp_replace(coalesce(sm2.contact_phone, ''), '\D', '', 'g'), 10) <> ''
  order by sm2.sent_at desc nulls last
  limit 1
) last_msg on true
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

drop materialized view if exists public.redline_contacts_unified_matview;
create materialized view public.redline_contacts_unified_matview as
select * from public.redline_contacts_unified;

create unique index if not exists redline_contacts_unified_matview_cid_uq
  on public.redline_contacts_unified_matview (contact_id);

create index if not exists redline_contacts_unified_matview_activity_idx
  on public.redline_contacts_unified_matview (last_activity desc nulls last);

grant select on public.redline_contacts to anon;
grant select on public.redline_contacts_unified to anon;
grant select on public.redline_contacts_unified_matview to anon;

-- 5) BACKFILL
-- Interactions
update public.interactions
set project_id = public.get_contact_anchored_project_id(contact_id)
where project_id is null 
  and contact_id is not null
  and public.get_contact_anchored_project_id(contact_id) is not null;

-- Span Attributions
update public.span_attributions
set applied_project_id = public.get_contact_anchored_project_id(sub.contact_id),
    needs_review = false,
    decision = 'assign',
    confidence = 1.0,
    attribution_source = 'anchored_contact',
    reasoning = coalesce(reasoning || ' ', '') || '(Backfill: single-project contact auto-attribution)'
from (
  select s.id as span_id, i.contact_id
  from public.conversation_spans s
  join public.interactions i on i.interaction_id = s.interaction_id
  where i.contact_id is not null
) sub
where span_attributions.span_id = sub.span_id
  and span_attributions.applied_project_id is null
  and public.get_contact_anchored_project_id(sub.contact_id) is not null;

commit;
