-- RPC functions for alias management: promote, retire, collision-check.
-- Prerequisites: project_aliases.active column, suggested_aliases table,
-- v_project_alias_lookup view.

-- ============================================================
-- RPC 1: promote_alias
-- Promotes a pending suggested_aliases row into project_aliases.
-- ============================================================
CREATE OR REPLACE FUNCTION promote_alias(
  p_suggestion_id uuid,
  p_reviewed_by text
) RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_project_id uuid;
  v_alias text;
  v_alias_type text;
  v_confidence numeric;
  v_already_exists boolean;
BEGIN
  -- Fetch the pending suggestion
  SELECT project_id, alias, alias_type, confidence
  INTO v_project_id, v_alias, v_alias_type, v_confidence
  FROM suggested_aliases
  WHERE id = p_suggestion_id
    AND status = 'pending';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found_or_not_pending');
  END IF;

  -- Check if an active alias already exists for this project + alias
  SELECT EXISTS (
    SELECT 1
    FROM project_aliases
    WHERE project_id = v_project_id
      AND lower(alias) = lower(v_alias)
      AND active = true
  ) INTO v_already_exists;

  -- Insert only if no active duplicate exists
  IF NOT v_already_exists THEN
    INSERT INTO project_aliases (project_id, alias, alias_type, source, confidence, created_by)
    VALUES (v_project_id, v_alias, v_alias_type, 'alias-review', v_confidence, p_reviewed_by);
  END IF;

  -- Mark suggestion as approved regardless
  UPDATE suggested_aliases
  SET status = 'approved',
      reviewed_at = now(),
      reviewed_by = p_reviewed_by
  WHERE id = p_suggestion_id;

  RETURN jsonb_build_object('ok', true, 'alias', v_alias, 'project_id', v_project_id);
END;
$$;
COMMENT ON FUNCTION promote_alias(uuid, text) IS
  'Promotes a pending suggested alias into project_aliases and marks the suggestion approved.';
-- ============================================================
-- RPC 2: retire_aliases_for_closed_projects
-- Deactivates aliases for closed/inactive projects.
-- ============================================================
CREATE OR REPLACE FUNCTION retire_aliases_for_closed_projects()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_affected_count integer;
  v_affected_projects uuid[];
BEGIN
  WITH retired AS (
    UPDATE project_aliases pa
    SET active = false
    FROM projects p
    WHERE pa.project_id = p.id
      AND p.status IN ('closed', 'inactive')
      AND pa.active = true
    RETURNING pa.project_id
  )
  SELECT count(*), array_agg(DISTINCT project_id)
  INTO v_affected_count, v_affected_projects
  FROM retired;

  RETURN jsonb_build_object(
    'ok', true,
    'retired_count', v_affected_count,
    'affected_project_ids', to_jsonb(COALESCE(v_affected_projects, ARRAY[]::uuid[]))
  );
END;
$$;
COMMENT ON FUNCTION retire_aliases_for_closed_projects() IS
  'Sets active=false on all project_aliases rows where the project status is closed or inactive.';
-- ============================================================
-- RPC 3: check_project_alias_collision
-- Checks if a proposed alias collides with other projects.
-- ============================================================
CREATE OR REPLACE FUNCTION check_project_alias_collision(
  p_alias text,
  p_project_id uuid
) RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_collisions jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'project_id', project_id,
    'alias', alias
  )), '[]'::jsonb)
  INTO v_collisions
  FROM v_project_alias_lookup
  WHERE lower(alias) = lower(p_alias)
    AND project_id != p_project_id;

  RETURN v_collisions;
END;
$$;
COMMENT ON FUNCTION check_project_alias_collision(text, uuid) IS
  'Returns a JSON array of collisions where the given alias is already used by other projects.';
