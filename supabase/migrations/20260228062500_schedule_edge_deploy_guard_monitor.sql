-- Schedule edge deploy guard monitor heartbeat/alerts.

do $do$
declare
  v_job_id bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      select jobid
      into v_job_id
      from cron.job
      where jobname = 'edge_deploy_guard_monitor_10m'
      order by jobid desc
      limit 1;

      if v_job_id is not null then
        perform cron.unschedule(v_job_id);
      end if;

      perform cron.schedule(
        'edge_deploy_guard_monitor_10m',
        '*/10 * * * *',
        $$select public.run_edge_deploy_guard_monitor('system:edge_deploy_guard_monitor_cron');$$
      );
    exception
      when others then
        raise notice 'edge_deploy_guard_monitor_10m cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

