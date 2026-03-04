-- Migration: harden_scheduler_backfill_cron
-- Goal: make the scheduler-backfill cron wiring robust across environments by:
-- - guarding against missing pg_net / supabase_vault / pg_cron
-- - normalizing supabase_url to avoid double-slash URLs
--
-- NOTE: This is safe to apply even if 20260304161500_wire_scheduler_backfill_cron.sql
-- already ran; it replaces the function and (re)ensures the cron job exists.

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
  v_has_pg_net boolean;
  v_has_vault boolean;
BEGIN
  select exists (select 1 from pg_extension where extname = 'pg_net') into v_has_pg_net;
  if not v_has_pg_net then
    raise notice 'cron_fire_scheduler_backfill: pg_net extension missing; skipping';
    return -2;
  end if;

  select exists (select 1 from pg_extension where extname = 'supabase_vault') into v_has_vault;

  v_base_url := coalesce(
    current_setting('app.settings.supabase_url', true),
    'https://rjhdwidddtfetbwqolof.supabase.co'
  );
  -- Avoid accidental "//functions/..." if the URL is configured with a trailing slash.
  v_base_url := rtrim(v_base_url, '/');

  v_anon_key := current_setting('app.settings.anon_key', true);
  if v_anon_key is null and v_has_vault then
    select decrypted_secret into v_anon_key
    from vault.decrypted_secrets
    where name = 'supabase_anon_key'
    limit 1;
  end if;

  v_edge_secret := current_setting('app.settings.edge_shared_secret', true);
  if v_edge_secret is null and v_has_vault then
    select decrypted_secret into v_edge_secret
    from vault.decrypted_secrets
    where name = 'edge_shared_secret'
    limit 1;
  end if;

  if v_anon_key is null or v_edge_secret is null then
    if not v_has_vault then
      raise notice 'cron_fire_scheduler_backfill: missing anon_key or edge_secret and supabase_vault not installed; skipping';
    else
      raise notice 'cron_fire_scheduler_backfill: missing anon_key or edge_secret, skipping';
    end if;
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

revoke execute on function public.cron_fire_scheduler_backfill() from public;
grant execute on function public.cron_fire_scheduler_backfill() to service_role;

-- Ensure schedule exists; if pg_cron is absent, emit a notice instead of failing silently.
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      if not exists (select 1 from cron.job where jobname = 'scheduler_backfill_every_5m') then
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
  else
    raise notice 'pg_cron extension missing; scheduler_backfill_every_5m not scheduled';
  end if;
end;
$do$;
