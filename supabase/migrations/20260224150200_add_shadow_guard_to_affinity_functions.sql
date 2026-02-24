-- Shadow guard for affinity functions
-- Prevents GT batch shadow runs (cll_SHADOW%, sms_thread_SHADOW%) from inflating
-- correspondent_project_affinity.confirmation_count and weight.
--
-- Contamination path: 58 shadow interactions had both project_id and contact_id set,
-- triggering trg_update_correspondent_affinity and inflating affinity across 10 projects.
--
-- Guards applied to:
--   1) is_shadow_interaction() — reusable helper
--   2) update_correspondent_project_affinity() — trigger on interactions table
--   3) update_affinity_on_attribution() — RPC called by router
--   4) upsert_affinity_feedback() — feedback/validation path
--   5) update_affinity_on_override() — human override path

-- 1) Helper function
CREATE OR REPLACE FUNCTION public.is_shadow_interaction(p_interaction_id text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_interaction_id LIKE 'cll_SHADOW%'
      OR p_interaction_id LIKE 'sms_thread_SHADOW%';
$$;

COMMENT ON FUNCTION public.is_shadow_interaction IS
'Returns true if the interaction_id belongs to a GT batch shadow run. Used by affinity guards to prevent shadow runs from inflating confirmation_count/weight.';

-- 2) Trigger function on interactions (primary contamination vector)
CREATE OR REPLACE FUNCTION public.update_correspondent_project_affinity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  -- Shadow guard: GT batch shadow runs must not inflate affinity
  IF is_shadow_interaction(NEW.interaction_id) THEN
    RETURN NEW;
  END IF;

  IF NEW.project_id IS NOT NULL AND NEW.contact_id IS NOT NULL THEN
    PERFORM set_config('camber.trusted_cpa_write', 'true', true);

    INSERT INTO correspondent_project_affinity (contact_id, project_id, weight, confirmation_count, last_interaction_at, source)
    VALUES (NEW.contact_id, NEW.project_id, 1.0, 1, NEW.event_at_utc, 'auto_derived')
    ON CONFLICT (contact_id, project_id)
    DO UPDATE SET
      confirmation_count = correspondent_project_affinity.confirmation_count + 1,
      last_interaction_at = GREATEST(correspondent_project_affinity.last_interaction_at, NEW.event_at_utc),
      updated_at = NOW();

    UPDATE correspondent_project_affinity cpa
    SET weight = cpa.confirmation_count::numeric / NULLIF(total.cnt, 0)::numeric
    FROM (
      SELECT contact_id, SUM(confirmation_count) as cnt
      FROM correspondent_project_affinity
      WHERE contact_id = NEW.contact_id
      GROUP BY contact_id
    ) total
    WHERE cpa.contact_id = NEW.contact_id
      AND cpa.contact_id = total.contact_id;

    PERFORM set_config('camber.trusted_cpa_write', 'false', true);
  END IF;
  RETURN NEW;
END;
$function$;

-- 3) RPC: update_affinity_on_attribution (added p_interaction_id param)
CREATE OR REPLACE FUNCTION public.update_affinity_on_attribution(
  p_contact_id uuid,
  p_project_id uuid,
  p_confidence numeric,
  p_source text DEFAULT 'router_attribution'::text,
  p_interaction_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE v_weight_delta numeric;
BEGIN
  IF p_interaction_id IS NOT NULL AND is_shadow_interaction(p_interaction_id) THEN
    RETURN;
  END IF;

  PERFORM set_config('camber.trusted_cpa_write', 'true', true);
  IF p_confidence >= 0.8 THEN
    v_weight_delta := 0.1 * p_confidence;
    INSERT INTO correspondent_project_affinity
      (id, contact_id, project_id, weight, confirmation_count, source, last_interaction_at, created_at, updated_at)
    VALUES (gen_random_uuid(), p_contact_id, p_project_id, v_weight_delta, 1, p_source, now(), now(), now())
    ON CONFLICT (contact_id, project_id) DO UPDATE SET
      weight = LEAST(correspondent_project_affinity.weight + v_weight_delta, 2.0),
      confirmation_count = correspondent_project_affinity.confirmation_count + 1,
      last_interaction_at = now(), updated_at = now();
  END IF;
END;
$function$;

-- 4) RPC: upsert_affinity_feedback (added p_interaction_id param)
CREATE OR REPLACE FUNCTION public.upsert_affinity_feedback(
  p_contact_id uuid,
  p_project_id uuid,
  p_action text,
  p_source text DEFAULT 'override'::text,
  p_interaction_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE v_weight_delta numeric; v_result jsonb;
BEGIN
  IF p_interaction_id IS NOT NULL AND is_shadow_interaction(p_interaction_id) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'shadow_interaction');
  END IF;

  PERFORM set_config('camber.trusted_cpa_write', 'true', true);
  IF p_action NOT IN ('confirm', 'reject') THEN
    RAISE EXCEPTION 'Invalid action: %. Must be confirm or reject.', p_action;
  END IF;
  v_weight_delta := CASE WHEN p_action = 'confirm' THEN 1 ELSE -1 END;
  INSERT INTO correspondent_project_affinity (
    id, contact_id, project_id, weight, confirmation_count, rejection_count,
    last_interaction_at, source, created_at, updated_at
  ) VALUES (
    gen_random_uuid(), p_contact_id, p_project_id, GREATEST(0, v_weight_delta),
    CASE WHEN p_action = 'confirm' THEN 1 ELSE 0 END,
    CASE WHEN p_action = 'reject' THEN 1 ELSE 0 END,
    now(), p_source, now(), now()
  )
  ON CONFLICT (contact_id, project_id) DO UPDATE SET
    weight = GREATEST(0, correspondent_project_affinity.weight + v_weight_delta),
    confirmation_count = correspondent_project_affinity.confirmation_count +
      CASE WHEN p_action = 'confirm' THEN 1 ELSE 0 END,
    rejection_count = correspondent_project_affinity.rejection_count +
      CASE WHEN p_action = 'reject' THEN 1 ELSE 0 END,
    last_interaction_at = now(), updated_at = now()
  RETURNING jsonb_build_object(
    'contact_id', contact_id, 'project_id', project_id,
    'weight', weight, 'confirmation_count', confirmation_count,
    'rejection_count', rejection_count, 'action', p_action
  ) INTO v_result;
  RETURN v_result;
END;
$function$;

-- 5) RPC: update_affinity_on_override (added p_interaction_id param)
CREATE OR REPLACE FUNCTION public.update_affinity_on_override(
  p_contact_id uuid,
  p_project_id uuid,
  p_is_confirmation boolean,
  p_interaction_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  IF p_interaction_id IS NOT NULL AND is_shadow_interaction(p_interaction_id) THEN
    RETURN;
  END IF;

  PERFORM set_config('camber.trusted_cpa_write', 'true', true);
  IF p_is_confirmation THEN
    INSERT INTO correspondent_project_affinity
      (id, contact_id, project_id, weight, confirmation_count, source, last_interaction_at, created_at, updated_at)
    VALUES (gen_random_uuid(), p_contact_id, p_project_id, 0.3, 1, 'human_override', now(), now(), now())
    ON CONFLICT (contact_id, project_id) DO UPDATE SET
      weight = LEAST(correspondent_project_affinity.weight + 0.3, 2.0),
      confirmation_count = correspondent_project_affinity.confirmation_count + 1,
      source = 'human_override', last_interaction_at = now(), updated_at = now();
  ELSE
    UPDATE correspondent_project_affinity
    SET weight = GREATEST(weight - 0.2, 0.0),
        rejection_count = COALESCE(rejection_count, 0) + 1, updated_at = now()
    WHERE contact_id = p_contact_id AND project_id = p_project_id;
  END IF;
END;
$function$;
