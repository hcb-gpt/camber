-- Phase 1: materialize context query surface for Redline/Camber interface.
-- Targets:
--  - public.v_project_feed          -> public.mat_project_context
--  - public.v_contact_activity_summary -> public.mat_contact_context
--  - public.v_project_belief_snapshot  -> public.mat_belief_context
-- Includes refresh status tracking for "last updated" UX and a safe refresh function.

begin;

create table if not exists public.context_surface_refresh_status (
  surface_name text primary key,
  last_refreshed_at_utc timestamptz not null,
  refreshed_by text not null default current_user
);

comment on table public.context_surface_refresh_status is
  'Refresh status registry for materialized context surfaces used by Redline/Camber UI and query endpoints.';

comment on column public.context_surface_refresh_status.last_refreshed_at_utc is
  'UTC timestamp of most recent successful refresh for each materialized context surface.';

create or replace function public.set_context_surface_refreshed(
  p_surface_name text,
  p_refreshed_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.context_surface_refresh_status as css (
    surface_name,
    last_refreshed_at_utc,
    refreshed_by
  )
  values (
    p_surface_name,
    p_refreshed_at,
    current_user
  )
  on conflict (surface_name) do update
    set last_refreshed_at_utc = excluded.last_refreshed_at_utc,
        refreshed_by = excluded.refreshed_by;
end;
$$;

comment on function public.set_context_surface_refreshed(text, timestamptz) is
  'Upserts refresh timestamps for context materialized views.';

drop materialized view if exists public.mat_project_context;
create materialized view public.mat_project_context as
select
  vpf.*,
  now() as materialized_at_utc
from public.v_project_feed vpf;

create unique index mat_project_context_project_id_uq
  on public.mat_project_context (project_id);

create index mat_project_context_last_interaction_idx
  on public.mat_project_context (last_interaction_at desc nulls last);

drop materialized view if exists public.mat_contact_context;
create materialized view public.mat_contact_context as
select
  vcas.*,
  now() as materialized_at_utc
from public.v_contact_activity_summary vcas;

create unique index mat_contact_context_contact_id_uq
  on public.mat_contact_context (contact_id);

create index mat_contact_context_last_call_idx
  on public.mat_contact_context (last_call_date desc nulls last);

drop materialized view if exists public.mat_belief_context;
create materialized view public.mat_belief_context as
select
  vpbs.project_id,
  vpbs.project_name,
  vpbs.snapshot,
  case
    when coalesce(vpbs.snapshot->>'snapshot_generated_at_utc', '') <> ''
      then (vpbs.snapshot->>'snapshot_generated_at_utc')::timestamptz
    else null
  end as snapshot_generated_at_utc,
  now() as materialized_at_utc
from public.v_project_belief_snapshot vpbs;

create unique index mat_belief_context_project_id_uq
  on public.mat_belief_context (project_id);

create index mat_belief_context_generated_at_idx
  on public.mat_belief_context (snapshot_generated_at_utc desc nulls last);

create or replace function public.refresh_materialized_context_views()
returns table(surface_name text, last_refreshed_at_utc timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  refresh materialized view public.mat_project_context;
  perform public.set_context_surface_refreshed('mat_project_context', now());

  refresh materialized view public.mat_contact_context;
  perform public.set_context_surface_refreshed('mat_contact_context', now());

  refresh materialized view public.mat_belief_context;
  perform public.set_context_surface_refreshed('mat_belief_context', now());

  return query
  select css.surface_name, css.last_refreshed_at_utc
  from public.context_surface_refresh_status css
  where css.surface_name in (
    'mat_project_context',
    'mat_contact_context',
    'mat_belief_context'
  )
  order by css.surface_name;
end;
$$;

comment on function public.refresh_materialized_context_views() is
  'Safe non-concurrent refresh for phase-1 context materialized views. Callable from pipeline completion hooks.';

create or replace view public.v_context_surface_refresh_status as
select
  css.surface_name,
  css.last_refreshed_at_utc,
  css.refreshed_by,
  greatest(extract(epoch from (now() - css.last_refreshed_at_utc)), 0)::bigint as age_seconds
from public.context_surface_refresh_status css;

comment on view public.v_context_surface_refresh_status is
  'Last refresh timestamps for context materialized views, including age in seconds for UI staleness messaging.';

-- seed/update status rows on migration apply
select public.set_context_surface_refreshed('mat_project_context', now());
select public.set_context_surface_refreshed('mat_contact_context', now());
select public.set_context_surface_refreshed('mat_belief_context', now());

-- REST visibility + service execution
grant select on public.mat_project_context to anon, authenticated, service_role;
grant select on public.mat_contact_context to anon, authenticated, service_role;
grant select on public.mat_belief_context to anon, authenticated, service_role;
grant select on public.context_surface_refresh_status to anon, authenticated, service_role;
grant select on public.v_context_surface_refresh_status to anon, authenticated, service_role;

grant execute on function public.refresh_materialized_context_views() to service_role;
grant execute on function public.set_context_surface_refreshed(text, timestamptz) to service_role;

-- nudge PostgREST schema cache to reduce PGRST205-style lag after deploy.
do $$
begin
  perform pg_notify('pgrst', 'reload schema');
exception
  when others then
    raise notice 'pgrst schema reload notify skipped: %', sqlerrm;
end;
$$;

commit;
