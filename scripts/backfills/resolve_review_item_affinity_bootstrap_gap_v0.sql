-- resolve_review_item_affinity_bootstrap_gap_v0.sql
-- Purpose: close missing correspondent_project_affinity rows for historical
-- human-resolved review_queue items.
--
-- Usage (intentional write):
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f scripts/backfills/resolve_review_item_affinity_bootstrap_gap_v0.sql

with candidates as (
  select
    i.contact_id,
    sa.applied_project_id as project_id,
    max(rq.resolved_at) as last_interaction_at
  from public.review_queue rq
  join public.span_attributions sa
    on sa.span_id = rq.span_id
   and sa.attribution_lock = 'human'
  join public.interactions i
    on i.interaction_id = rq.interaction_id
  join public.contacts ct
    on ct.id = i.contact_id
  left join public.correspondent_project_affinity cpa
    on cpa.contact_id = i.contact_id
   and cpa.project_id = sa.applied_project_id
  where rq.status = 'resolved'
    and i.contact_id is not null
    and sa.applied_project_id is not null
    and lower(coalesce(ct.contact_type, '')) != 'internal'
    and coalesce(ct.floats_between_projects, false) = false
    and cpa.id is null
  group by i.contact_id, sa.applied_project_id
), upserted as (
  insert into public.correspondent_project_affinity (
    id,
    contact_id,
    project_id,
    weight,
    confirmation_count,
    rejection_count,
    last_interaction_at,
    source,
    created_at,
    updated_at
  )
  select
    gen_random_uuid(),
    c.contact_id,
    c.project_id,
    1,
    1,
    0,
    c.last_interaction_at,
    'redline_backfill',
    now(),
    now()
  from candidates c
  on conflict (contact_id, project_id) do update set
    weight = public.correspondent_project_affinity.weight + 1,
    confirmation_count = public.correspondent_project_affinity.confirmation_count + 1,
    last_interaction_at = greatest(
      coalesce(public.correspondent_project_affinity.last_interaction_at, '-infinity'::timestamptz),
      coalesce(excluded.last_interaction_at, '-infinity'::timestamptz)
    ),
    updated_at = now()
  returning contact_id, project_id
)
select count(*) as rows_touched
from upserted;
