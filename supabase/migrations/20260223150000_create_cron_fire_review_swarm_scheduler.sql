-- Cron trigger for review-swarm-scheduler edge function
-- Uses pg_net to POST to the edge function every 5 minutes.
-- The scheduler itself decides whether to fire the runner based on backlog metrics.

begin;

-- pg_net wrapper function: POST to review-swarm-scheduler edge function
create or replace function public.cron_fire_review_swarm_scheduler()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_request_id bigint;
begin
  -- Read config from Supabase vault or app.settings
  v_base_url := coalesce(
    current_setting('app.settings.supabase_url', true),
    'https://rjhdwidddtfetbwqolof.supabase.co'
  );
  v_anon_key := coalesce(
    current_setting('app.settings.anon_key', true),
    (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1)
  );
  v_edge_secret := coalesce(
    current_setting('app.settings.edge_shared_secret', true),
    (select decrypted_secret from vault.decrypted_secrets where name = 'edge_shared_secret' limit 1)
  );

  if v_anon_key is null or v_edge_secret is null then
    raise notice 'cron_fire_review_swarm_scheduler: missing anon_key or edge_secret, skipping';
    return -1;
  end if;

  select net.http_post(
    url := v_base_url || '/functions/v1/review-swarm-scheduler',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'X-Edge-Secret', v_edge_secret,
      'X-Source', 'cron'
    ),
    body := '{}'::jsonb
  ) into v_request_id;

  return v_request_id;
end;
$$;

comment on function public.cron_fire_review_swarm_scheduler() is
  'pg_net wrapper: fires review-swarm-scheduler edge function. Returns pg_net request_id.';

grant execute on function public.cron_fire_review_swarm_scheduler() to service_role;

-- Schedule: every 5 minutes
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'review_swarm_scheduler_5min'
      ) then
        perform cron.schedule(
          'review_swarm_scheduler_5min',
          '*/5 * * * *',
          $$select public.cron_fire_review_swarm_scheduler();$$
        );
      end if;
    exception
      when others then
        raise notice 'review_swarm_scheduler cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

commit;
