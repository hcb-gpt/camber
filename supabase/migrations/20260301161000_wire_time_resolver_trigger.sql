-- Wire time-resolver to scheduler_items via DB trigger
-- Created: 2026-03-01
-- Task: directive__wire_time_resolver_to_pipeline (Option A)

BEGIN;

-- 1. Ensure time_resolution_audit exists (created in 20260301040000 but double check)
-- Table is already created in 20260301040000_time_resolution_audit.sql

-- 2. Create trigger function to fire edge function
CREATE OR REPLACE FUNCTION public.trg_fn_resolve_scheduler_item_time()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_url text;
  v_anon_key text;
  v_edge_secret text;
  v_request_id bigint;
BEGIN
  -- Only fire if time_hint is present and timestamps are NULL
  IF NEW.time_hint IS NULL OR NEW.time_hint = '' THEN
    RETURN NEW;
  END IF;

  IF NEW.start_at_utc IS NOT NULL OR NEW.due_at_utc IS NOT NULL THEN
    RETURN NEW;
  END IF;

  v_base_url := coalesce(
    current_setting('app.settings.supabase_url', true),
    'https://rjhdwidddtfetbwqolof.supabase.co'
  );
  
  -- Try to get from vault, fallback to app settings
  v_anon_key := (select decrypted_secret from vault.decrypted_secrets where name = 'supabase_anon_key' limit 1);
  IF v_anon_key IS NULL THEN
    v_anon_key := current_setting('app.settings.anon_key', true);
  END IF;

  v_edge_secret := (select decrypted_secret from vault.decrypted_secrets where name = 'edge_shared_secret' limit 1);
  IF v_edge_secret IS NULL THEN
    v_edge_secret := current_setting('app.settings.edge_shared_secret', true);
  END IF;

  IF v_anon_key IS NULL OR v_edge_secret IS NULL THEN
    RAISE WARNING 'trg_fn_resolve_scheduler_item_time: missing anon_key or edge_secret, skipping';
    RETURN NEW;
  END IF;

  -- Fire-and-forget call to resolve-scheduler-time edge function
  SELECT net.http_post(
    url := v_base_url || '/functions/v1/resolve-scheduler-time',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'X-Edge-Secret', v_edge_secret,
      'X-Source', 'scheduler-trigger'
    ),
    body := jsonb_build_object(
      'scheduler_item_id', NEW.id,
      'time_hint', NEW.time_hint,
      'interaction_id', NEW.interaction_id
    )
  ) INTO v_request_id;

  RETURN NEW;
END;
$$;

-- 3. Create the trigger
DROP TRIGGER IF EXISTS trg_resolve_scheduler_item_time ON public.scheduler_items;

CREATE TRIGGER trg_resolve_scheduler_item_time
AFTER INSERT ON public.scheduler_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_fn_resolve_scheduler_item_time();

COMMENT ON FUNCTION public.trg_fn_resolve_scheduler_item_time() IS 
  'Trigger function to fire resolve-scheduler-time edge function when new items land with time_hints.';

COMMIT;
