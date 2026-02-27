-- Create v_project_activity_timeline
-- Unified chronological feed per project across calls, SMS, claims, tasks, and timeline events.

create or replace view public.v_project_activity_timeline as
with interactions_map as (
  select
    i.id as interaction_uuid,
    i.interaction_id,
    i.thread_key,
    i.project_id,
    i.contact_name
  from public.interactions i
),
calls_src as (
  select
    im.project_id,
    p.name as project_name,
    coalesce(cr.event_at_utc, cr.ingested_at_utc) as event_timestamp,
    'call'::text as event_type,
    coalesce(nullif(cr.summary, ''), left(coalesce(cr.transcript, ''), 240), 'call event') as summary,
    coalesce(cr.other_party_name, im.contact_name) as contact_name,
    'calls_raw'::text as source_table,
    cr.id::text as source_id
  from public.calls_raw cr
  join interactions_map im
    on im.interaction_id = cr.interaction_id
  join public.projects p
    on p.id = im.project_id
),
sms_src as (
  with sms_project_candidates as (
    select
      sm.id as sms_id,
      im.project_id,
      1 as priority
    from public.sms_messages sm
    join interactions_map im
      on im.thread_key = sm.thread_id
    where im.project_id is not null

    union all

    select
      sm.id as sms_id,
      pc.project_id,
      2 as priority
    from public.sms_messages sm
    join public.contacts c
      on c.phone = sm.contact_phone
      or c.secondary_phone = sm.contact_phone
    join public.project_contacts pc
      on pc.contact_id = c.id
     and pc.is_active = true
  ),
  sms_project_map as (
    select distinct on (sms_id)
      sms_id,
      project_id
    from sms_project_candidates
    order by sms_id, priority asc
  )
  select
    spm.project_id,
    p.name as project_name,
    coalesce(sm.sent_at, sm.ingested_at) as event_timestamp,
    'sms'::text as event_type,
    coalesce(left(sm.content, 240), 'sms event') as summary,
    sm.contact_name,
    'sms_messages'::text as source_table,
    sm.id::text as source_id
  from public.sms_messages sm
  join sms_project_map spm
    on spm.sms_id = sm.id
  join public.projects p
    on p.id = spm.project_id
),
claims_src as (
  select
    jc.project_id,
    p.name as project_name,
    jc.created_at as event_timestamp,
    'claim'::text as event_type,
    coalesce(left(jc.claim_text, 240), 'claim event') as summary,
    null::text as contact_name,
    'journal_claims'::text as source_table,
    jc.id::text as source_id
  from public.journal_claims jc
  join public.projects p
    on p.id = jc.project_id
),
tasks_src as (
  select
    coalesce(si.project_id, im.project_id) as project_id,
    p.name as project_name,
    coalesce(si.start_at_utc, si.due_at_utc, si.created_at) as event_timestamp,
    'task'::text as event_type,
    coalesce(
      nullif(si.title, ''),
      nullif(si.description, ''),
      concat('scheduler item: ', coalesce(si.item_type, 'task'))
    ) as summary,
    im.contact_name as contact_name,
    'scheduler_items'::text as source_table,
    si.id::text as source_id
  from public.scheduler_items si
  left join interactions_map im
    on im.interaction_uuid = si.interaction_id
  join public.projects p
    on p.id = coalesce(si.project_id, im.project_id)
),
timeline_src as (
  select
    pte.project_id,
    p.name as project_name,
    pte.event_time as event_timestamp,
    'timeline_event'::text as event_type,
    coalesce(nullif(pte.notes, ''), pte.event_type, 'timeline event') as summary,
    pte.contact_name,
    coalesce(nullif(pte.source_table, ''), 'project_timeline_events') as source_table,
    coalesce(pte.source_row_id::text, pte.id::text) as source_id
  from public.project_timeline_events pte
  join public.projects p
    on p.id = pte.project_id
)
select * from calls_src
union all
select * from sms_src
union all
select * from claims_src
union all
select * from tasks_src
union all
select * from timeline_src;
comment on view public.v_project_activity_timeline is
  'Unified chronological activity feed per project from calls_raw, sms_messages, journal_claims, scheduler_items, and project_timeline_events.';
