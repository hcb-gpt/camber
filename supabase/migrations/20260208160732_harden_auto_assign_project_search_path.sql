
CREATE OR REPLACE FUNCTION public.auto_assign_project(p_interaction_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public
AS $function$
DECLARE
  v_contact_id uuid;
  v_candidate_projects jsonb;
  v_project_count int;
  v_top_candidate jsonb;
  v_top_project_id uuid;
  v_top_score numeric;
  v_second_score numeric;
  v_confidence numeric;
  v_num_candidates int;
BEGIN
  -- Fetch interaction data
  SELECT contact_id, candidate_projects
  INTO v_contact_id, v_candidate_projects
  FROM interactions
  WHERE interaction_id = p_interaction_id;

  IF v_contact_id IS NULL THEN
    RETURN jsonb_build_object('assigned', false, 'reason', 'no_contact_id');
  END IF;

  -- Count active client projects for this contact
  SELECT COUNT(*) INTO v_project_count
  FROM project_contacts pc
  JOIN projects p ON p.id = pc.project_id
  WHERE pc.contact_id = v_contact_id
    AND pc.is_active = true
    AND p.status IN ('active', 'warranty', 'estimating')
    AND p.project_kind = 'client';

  -- RULE 1: Single-project contact → auto-assign
  IF v_project_count = 1 THEN
    SELECT p.id INTO v_top_project_id
    FROM project_contacts pc
    JOIN projects p ON p.id = pc.project_id
    WHERE pc.contact_id = v_contact_id
      AND pc.is_active = true
      AND p.status IN ('active', 'warranty', 'estimating')
      AND p.project_kind = 'client'
    LIMIT 1;

    UPDATE interactions
    SET project_id = v_top_project_id,
        needs_review = false,
        review_reasons = ARRAY['auto_assigned_single_project_contact']
    WHERE interaction_id = p_interaction_id;

    RETURN jsonb_build_object(
      'assigned', true,
      'reason', 'single_project_contact',
      'project_id', v_top_project_id,
      'contact_project_count', v_project_count
    );
  END IF;

  -- Now check candidates for remaining rules
  IF v_candidate_projects IS NULL OR jsonb_array_length(v_candidate_projects) = 0 THEN
    RETURN jsonb_build_object(
      'assigned', false, 
      'reason', 'no_candidates',
      'contact_project_count', v_project_count
    );
  END IF;

  v_num_candidates := jsonb_array_length(v_candidate_projects);

  -- RULE 1.5 (R2): Solo candidate + contact has ≤3 active projects → auto-assign
  IF v_num_candidates = 1 AND v_project_count <= 3 THEN
    IF jsonb_typeof(v_candidate_projects->0) = 'string' THEN
      v_top_project_id := (v_candidate_projects->>0)::uuid;
    ELSE
      v_top_project_id := (v_candidate_projects->0->>'id')::uuid;
    END IF;

    IF EXISTS (
      SELECT 1 FROM projects p 
      WHERE p.id = v_top_project_id 
        AND p.status IN ('active', 'warranty', 'estimating')
    ) THEN
      UPDATE interactions
      SET project_id = v_top_project_id,
          needs_review = false,
          review_reasons = ARRAY['auto_assigned_solo_candidate_low_project_count']
      WHERE interaction_id = p_interaction_id;

      RETURN jsonb_build_object(
        'assigned', true,
        'reason', 'solo_candidate_low_project_count',
        'project_id', v_top_project_id,
        'contact_project_count', v_project_count,
        'num_candidates', v_num_candidates
      );
    END IF;
  END IF;

  -- RULE 2: Score-based auto-assign (v3 format only)
  IF jsonb_typeof(v_candidate_projects->0) = 'object' 
     AND v_candidate_projects->0 ? 'score' THEN
    
    SELECT c INTO v_top_candidate
    FROM jsonb_array_elements(v_candidate_projects) c
    ORDER BY (c->>'score')::numeric DESC
    LIMIT 1;

    v_top_score := (v_top_candidate->>'score')::numeric;
    v_top_project_id := (v_top_candidate->>'id')::uuid;
    v_confidence := (
      SELECT (c->>'confidence')::numeric 
      FROM jsonb_array_elements(v_candidate_projects) c 
      ORDER BY (c->>'score')::numeric DESC 
      LIMIT 1
    );

    IF v_num_candidates > 1 THEN
      SELECT (c->>'score')::numeric INTO v_second_score
      FROM jsonb_array_elements(v_candidate_projects) c
      ORDER BY (c->>'score')::numeric DESC
      OFFSET 1 LIMIT 1;
    ELSE
      v_second_score := 0;
    END IF;

    IF v_top_score >= 150 
       AND (v_second_score = 0 OR v_top_score >= v_second_score * 2)
       AND (v_confidence IS NULL OR v_confidence >= 0.55) THEN
      
      UPDATE interactions
      SET project_id = v_top_project_id,
          needs_review = false,
          review_reasons = ARRAY['auto_assigned_high_confidence_score']
      WHERE interaction_id = p_interaction_id;

      RETURN jsonb_build_object(
        'assigned', true,
        'reason', 'high_confidence_score',
        'project_id', v_top_project_id,
        'top_score', v_top_score,
        'second_score', v_second_score,
        'confidence', v_confidence,
        'contact_project_count', v_project_count
      );
    END IF;

    RETURN jsonb_build_object(
      'assigned', false,
      'reason', 'insufficient_evidence',
      'top_score', v_top_score,
      'second_score', v_second_score,
      'confidence', v_confidence,
      'contact_project_count', v_project_count
    );
  END IF;

  RETURN jsonb_build_object(
    'assigned', false,
    'reason', 'insufficient_evidence',
    'contact_project_count', v_project_count
  );
END;
$function$;
;
