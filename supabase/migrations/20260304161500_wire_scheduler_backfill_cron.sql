-- Migration: wire_scheduler_backfill_cron
-- Goal: hands-off time resolution for scheduler_items by invoking the existing
--       scheduler-backfill edge function on a cadence.
--
-- Why cron (vs trigger):
-- - Minimal change set (no new edge function required)
-- - Backfills existing stuck rows + keeps up with new inserts
-- - Backfill runs are already audited via backfill_runs + time_resolution_audit
--
-- Notes:
-- - Uses pg_net for HTTP + pg_cron for scheduling (if installed).
-- - Uses the same secret sources/pattern as other cron-fire wrappers:
--   app.settings.* (preferred) -> vault.decrypted_secrets fallback.

CREATE OR REPLACE FUNCTION public.cron_fire_scheduler_backfill()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_request_id bigint;
  v_pending bigint;
BEGIN
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
    raise notice 'cron_fire_scheduler_backfill: missing anon_key or edge_secret, skipping';
    return -1;
  end if;

  -- Fast skip: no eligible rows.
  select count(*)::bigint into v_pending
  from public.scheduler_items si
  where si.time_hint is not null
    and si.time_hint <> ''
    and si.start_at_utc is null
    and si.due_at_utc is null;

  if v_pending = 0 then
    return 0;
  end if;

  -- Invoke edge function (it self-limits to MAX_LIMIT=5000, MAX_BATCH_SIZE=200).
  select net.http_post(
    url := v_base_url || '/functions/v1/scheduler-backfill',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'X-Edge-Secret', v_edge_secret,
      -- Must be in scheduler-backfill allowlist.
      'X-Source', 'scheduler-backfill'
    ),
    body := jsonb_build_object(
      'target', 'scheduler_items',
      'batch_size', 200,
      'limit', 5000,
      'apply', true
    )
  ) into v_request_id;

  return v_request_id;
END;
$$;

comment on function public.cron_fire_scheduler_backfill() is
  'pg_net wrapper: invokes scheduler-backfill edge function to resolve scheduler_items time hints. Returns pg_net request_id. (Epic 1.2)';

grant execute on function public.cron_fire_scheduler_backfill() to service_role;

-- Schedule: every 5 minutes.
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (
        select 1
        from cron.job
        where jobname = 'scheduler_backfill_every_5m'
      ) then
        perform cron.schedule(
          'scheduler_backfill_every_5m',
          '*/5 * * * *',
          $$select public.cron_fire_scheduler_backfill();$$
        );
      end if;
    exception
      when others then
        raise notice 'scheduler_backfill cron registration skipped: %', sqlerrm;
    end;
  end if;
end;
$do$;

