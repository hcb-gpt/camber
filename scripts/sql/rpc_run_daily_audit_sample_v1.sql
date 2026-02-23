-- rpc_run_daily_audit_sample_v1.sql
--
-- Purpose:
-- - Create RPC public.run_daily_audit_sample_v1()
-- - Stratify by top-5 active projects by 24h span volume
-- - Select one random interaction_id per project for daily audit sampling
--
-- Usage:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f scripts/sql/rpc_run_daily_audit_sample_v1.sql
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -c "select * from public.run_daily_audit_sample_v1();"

create or replace function public.run_daily_audit_sample_v1()
returns table (
  interaction_id text,
  project_id uuid,
  project_name text,
  span_count bigint,
  sample_reason text
)
language sql
security definer
set search_path = public
as $$
  with span_volume_24h as (
    select
      i.project_id,
      count(*)::bigint as span_count_24h
    from public.conversation_spans cs
    join public.interactions i
      on i.interaction_id = cs.interaction_id
    where cs.is_superseded = false
      and i.project_id is not null
      and cs.created_at >= now() - interval '24 hours'
    group by i.project_id
  ),
  top_projects as (
    select
      sv.project_id,
      sv.span_count_24h
    from span_volume_24h sv
    order by sv.span_count_24h desc, sv.project_id
    limit 5
  ),
  project_call_candidates as (
    select
      tp.project_id,
      tp.span_count_24h,
      cs.interaction_id,
      row_number() over (
        partition by tp.project_id
        order by random(), cs.interaction_id
      ) as rn
    from top_projects tp
    join public.interactions i
      on i.project_id = tp.project_id
    join public.conversation_spans cs
      on cs.interaction_id = i.interaction_id
    where cs.is_superseded = false
      and cs.created_at >= now() - interval '24 hours'
  ),
  chosen as (
    select
      pcc.project_id,
      pcc.span_count_24h,
      pcc.interaction_id
    from project_call_candidates pcc
    where pcc.rn = 1
  )
  select
    c.interaction_id,
    c.project_id,
    p.name as project_name,
    c.span_count_24h as span_count,
    'top5_24h_span_volume_random_call_per_project'::text as sample_reason
  from chosen c
  left join public.projects p
    on p.id = c.project_id
  order by c.span_count_24h desc, c.project_id;
$$;

grant execute on function public.run_daily_audit_sample_v1()
to anon, authenticated, service_role;

