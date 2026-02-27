begin;

create or replace function public.refresh_redline_context_matviews()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  refresh materialized view public.mat_project_context;
  refresh materialized view public.mat_contact_context;
  refresh materialized view public.mat_belief_context;
end;
$$;

comment on function public.refresh_redline_context_matviews() is
  'Refreshes Redline context materialized views: mat_project_context, mat_contact_context, mat_belief_context.';

grant execute on function public.refresh_redline_context_matviews() to service_role;

do $do$
declare
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      select jobid
      into v_job_id
      from cron.job
      where jobname = 'refresh_redline_context_matviews_5m'
      order by jobid desc
      limit 1;

      if v_job_id is not null then
        perform cron.unschedule(v_job_id);
      end if;

      perform cron.schedule(
        'refresh_redline_context_matviews_5m',
        '*/5 * * * *',
        $$select public.refresh_redline_context_matviews();$$
      );
    exception
      when others then
        raise notice 'refresh_redline_context_matviews_5m cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
