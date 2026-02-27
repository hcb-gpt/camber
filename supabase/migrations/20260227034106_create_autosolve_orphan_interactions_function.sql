CREATE OR REPLACE FUNCTION public.autosolve_orphan_interactions(
  p_apply boolean DEFAULT false,
  p_rule text DEFAULT NULL,  -- filter to specific rule: CLIENT_BYPASS, SINGLE_ACTIVE, JUNCTION_SINGLE, or NULL for all
  p_contact_id uuid DEFAULT NULL  -- filter to specific contact, or NULL for all
)
RETURNS TABLE(
  interaction_id text,
  contact_name text,
  resolve_rule text,
  top_project_id uuid,
  top_project_name text,
  auto_confidence numeric,
  applied boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Return preview of what would be resolved
  RETURN QUERY
  SELECT 
    vac.interaction_id,
    vac.contact_name,
    vac.resolve_rule,
    vac.top_project_id,
    vac.top_project_name,
    vac.auto_confidence,
    false AS applied
  FROM v_autosolve_candidates vac
  WHERE vac.is_auto_resolvable = true
    AND (p_rule IS NULL OR vac.resolve_rule = p_rule)
    AND (p_contact_id IS NULL OR vac.contact_id = p_contact_id);

  -- Only apply if explicitly requested
  IF p_apply THEN
    UPDATE interactions i
    SET project_id = vac.top_project_id,
        updated_at = NOW()
    FROM v_autosolve_candidates vac
    WHERE i.interaction_id = vac.interaction_id
      AND vac.is_auto_resolvable = true
      AND (p_rule IS NULL OR vac.resolve_rule = p_rule)
      AND (p_contact_id IS NULL OR vac.contact_id = p_contact_id)
      AND i.project_id IS NULL;  -- safety: never overwrite existing attribution
  END IF;
END;
$function$;;
