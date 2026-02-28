-- bootstrap_affinity_gap_proof.sql
-- Read-only proof query: unresolved affinity edges for human-resolved review items.

with required_edges as (
  select distinct
    i.contact_id,
    sa.applied_project_id as project_id
  from public.review_queue rq
  join public.span_attributions sa
    on sa.span_id = rq.span_id
   and sa.attribution_lock = 'human'
  join public.interactions i
    on i.interaction_id = rq.interaction_id
  where rq.status = 'resolved'
    and i.contact_id is not null
    and sa.applied_project_id is not null
), missing as (
  select re.contact_id, re.project_id
  from required_edges re
  left join public.correspondent_project_affinity cpa
    on cpa.contact_id = re.contact_id
   and cpa.project_id = re.project_id
  where cpa.id is null
), missing_eligible as (
  select m.contact_id, m.project_id
  from missing m
  join public.contacts c
    on c.id = m.contact_id
  where lower(coalesce(c.contact_type, '')) != 'internal'
    and coalesce(c.floats_between_projects, false) = false
)
select
  now() as checked_at,
  (select count(*) from required_edges) as required_edges,
  (select count(*) from missing) as missing_affinity_edges_raw,
  (select count(*) from missing_eligible) as missing_affinity_edges_eligible;

select
  m.contact_id,
  m.project_id,
  c.contact_type,
  coalesce(c.floats_between_projects, false) as floats_between_projects
from (
  with required_edges as (
    select distinct
      i.contact_id,
      sa.applied_project_id as project_id
    from public.review_queue rq
    join public.span_attributions sa
      on sa.span_id = rq.span_id
     and sa.attribution_lock = 'human'
    join public.interactions i
      on i.interaction_id = rq.interaction_id
    where rq.status = 'resolved'
      and i.contact_id is not null
      and sa.applied_project_id is not null
  )
  select re.contact_id, re.project_id
  from required_edges re
  left join public.correspondent_project_affinity cpa
    on cpa.contact_id = re.contact_id
   and cpa.project_id = re.project_id
  where cpa.id is null
) m
left join public.contacts c
  on c.id = m.contact_id
order by m.contact_id, m.project_id
limit 25;
