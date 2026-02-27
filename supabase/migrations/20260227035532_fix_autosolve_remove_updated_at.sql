
CREATE OR REPLACE FUNCTION public.autosolve_orphan_interactions(
  p_apply boolean DEFAULT false,
  p_rule text DEFAULT NULL,
  p_contact_id uuid DEFAULT NULL
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

  IF p_apply THEN
    UPDATE interactions i
    SET project_id = vac.top_project_id
    FROM v_autosolve_candidates vac
    WHERE i.interaction_id = vac.interaction_id
      AND vac.is_auto_resolvable = true
      AND (p_rule IS NULL OR vac.resolve_rule = p_rule)
      AND (p_contact_id IS NULL OR vac.contact_id = p_contact_id)
      AND i.project_id IS NULL;
  END IF;
END;
$function$;
;
