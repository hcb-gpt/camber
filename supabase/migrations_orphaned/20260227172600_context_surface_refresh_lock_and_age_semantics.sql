-- Phase 1 acceptance patch:
-- - add advisory-lock guard to refresh function (avoid refresh storms)
-- - expose client-friendly "last updated" semantics and stale<=15m flag

begin;

create or replace view public.v_context_surface_refresh_status as
with base as (
  select
    css.surface_name,
    css.last_refreshed_at_utc,
    css.refreshed_by,
    greatest(extract(epoch from (now() - css.last_refreshed_at_utc)), 0)::bigint as age_seconds
  from public.context_surface_refresh_status css
)
select
  b.surface_name,
  b.last_refreshed_at_utc,
  b.refreshed_by,
  b.age_seconds,
  (b.age_seconds > 900) as is_stale_15m,
  case
    when b.age_seconds < 60 then concat(b.age_seconds::text, 's ago')
    when b.age_seconds < 3600 then concat((b.age_seconds / 60)::text, 'm ago')
    when b.age_seconds < 86400 then concat((b.age_seconds / 3600)::text, 'h ago')
    else concat((b.age_seconds / 86400)::text, 'd ago')
  end as last_updated_ago
from base b;

comment on view public.v_context_surface_refresh_status is
  'Refresh timestamps + staleness semantics for context materialized views (age_seconds, is_stale_15m, last_updated_ago).';

create or replace function public.refresh_materialized_context_views()
returns table(surface_name text, last_refreshed_at_utc timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lock_key bigint := hashtextextended('public.refresh_materialized_context_views', 0);
begin
  if not pg_try_advisory_lock(v_lock_key) then
    raise exception 'refresh_materialized_context_views already in progress';
  end if;

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

    perform pg_advisory_unlock(v_lock_key);
  exception
    when others then
      perform pg_advisory_unlock(v_lock_key);
      raise;
  end;
end;
$$;

comment on function public.refresh_materialized_context_views() is
  'Safe non-concurrent refresh for phase-1 context materialized views with advisory lock (one refresh at a time).';

grant select on public.v_context_surface_refresh_status to anon, authenticated, service_role;
grant execute on function public.refresh_materialized_context_views() to service_role;

-- nudge PostgREST schema cache so new view columns appear quickly.
do $$
begin
  perform pg_notify('pgrst', 'reload schema');
exception
  when others then
    raise notice 'pgrst schema reload notify skipped: %', sqlerrm;
end;
$$;

commit;
