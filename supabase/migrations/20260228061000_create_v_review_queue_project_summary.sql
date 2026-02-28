-- Per-project review_queue summary for assistant-context and operator dashboards.
-- Includes backlog (total pending) and velocity (pending created in 7d).

create index if not exists idx_review_queue_pending_interaction_created
  on public.review_queue (interaction_id, created_at)
  where status = 'pending';

create index if not exists idx_interactions_interaction_id_project
  on public.interactions (interaction_id, project_id);

create or replace view public.v_review_queue_project_summary as
select
  i.project_id,
  p.name as project_name,
  count(*) filter (where rq.status = 'pending')::int as pending_reviews_total,
  count(*) filter (
    where rq.status = 'pending'
      and rq.created_at >= now() - interval '7 days'
  )::int as pending_reviews_7d,
  min(rq.created_at) filter (where rq.status = 'pending') as oldest_pending_created_at,
  max(rq.created_at) filter (where rq.status = 'pending') as latest_pending_created_at,
  now() as computed_at_utc
from public.review_queue rq
join public.interactions i
  on i.interaction_id = rq.interaction_id
left join public.projects p
  on p.id = i.project_id
where rq.status = 'pending'
  and i.project_id is not null
group by i.project_id, p.name
order by pending_reviews_total desc, latest_pending_created_at desc nulls last;

grant select on public.v_review_queue_project_summary to authenticated, anon, service_role;

comment on view public.v_review_queue_project_summary is
'Per-project pending review_queue rollup with backlog (total pending) and 7d velocity fields for assistant-context and operator views.';

