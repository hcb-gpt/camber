-- Redline performance: cache contact list in a materialized view
-- Source: public.redline_contacts view
-- Refresh: concurrent cron every 1 minute

begin;

drop materialized view if exists public.redline_contacts_mv;

create materialized view public.redline_contacts_mv as
select
  contact_id,
  contact_name,
  contact_phone,
  call_count,
  sms_count,
  claim_count,
  ungraded_count,
  last_activity,
  last_snippet,
  last_direction,
  last_interaction_type
from public.redline_contacts;

create unique index redline_contacts_mv_contact_id_uq
  on public.redline_contacts_mv (contact_id);

create index redline_contacts_mv_ungraded_last_activity_idx
  on public.redline_contacts_mv (ungraded_count desc, last_activity desc);

comment on materialized view public.redline_contacts_mv is
  'Cached projection of redline_contacts for low-latency contact list reads.';

create or replace function public.refresh_redline_contacts_mv()
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_refreshed_at timestamptz := now();
begin
  refresh materialized view public.redline_contacts_mv;
  return v_refreshed_at;
end;
$$;

comment on function public.refresh_redline_contacts_mv() is
  'On-demand refresh for public.redline_contacts_mv (non-concurrent).';

grant select on public.redline_contacts_mv to service_role;
grant execute on function public.refresh_redline_contacts_mv() to service_role;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'redline_contacts_mv_refresh_1min'
      ) then
        perform cron.schedule(
          'redline_contacts_mv_refresh_1min',
          '*/1 * * * *',
          $$refresh materialized view concurrently public.redline_contacts_mv;$$
        );
      end if;
    exception
      when others then
        raise notice 'redline_contacts_mv cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
