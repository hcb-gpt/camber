-- cron_fire_sms_thread_assembler: pg_cron wrapper for sms-thread-assembler edge function
-- Scheduled: every 4h (0 */4 * * *)

CREATE OR REPLACE FUNCTION public.cron_fire_sms_thread_assembler()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_request_id bigint;
begin
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
    raise notice 'cron_fire_sms_thread_assembler: missing anon_key or edge_secret, skipping';
    return -1;
  end if;

  select net.http_post(
    url := v_base_url || '/functions/v1/sms-thread-assembler',
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
$function$;

-- Schedule every 4 hours
SELECT cron.schedule(
  'sms-thread-assembler-4h',
  '0 */4 * * *',
  'SELECT public.cron_fire_sms_thread_assembler();'
);
