
CREATE OR REPLACE FUNCTION public.get_project_state_snapshot(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_project       record;
  v_phase_name    text;
  v_commitments   jsonb;
  v_open_loops    jsonb;
  v_decisions     jsonb;
  v_contacts_mentioned jsonb;
  v_striking      jsonb;
  v_conflicts     jsonb;
  v_last_activity timestamptz;
  v_claim_counts  jsonb;
  v_system_record jsonb;
BEGIN
  -- =============================================
  -- 1. SYSTEM RECORD (from projects + construction_phases)
  -- =============================================
  SELECT p.id, p.name, p.status, p.phase, p.contract_value,
         p.address, p.street, p.city, p.state, p.zip, p.county,
         p.client_name, p.client_entity, p.job_type,
         p.subdivision_name, p.lot_number, p.project_kind,
         cp.display as construction_phase_display,
         cp.name as construction_phase_name,
         cp.sequence as construction_phase_sequence
  INTO v_project
  FROM projects p
  LEFT JOIN construction_phases cp ON cp.id = p.current_construction_phase_id
  WHERE p.id = p_project_id;

  IF v_project IS NULL THEN
    RETURN jsonb_build_object('error', 'project_not_found', 'project_id', p_project_id);
  END IF;

  v_phase_name := COALESCE(v_project.construction_phase_display, v_project.construction_phase_name, v_project.phase, 'unknown');

  v_system_record := jsonb_build_object(
    'name', v_project.name,
    'status', v_project.status,
    'phase', v_phase_name,
    'construction_phase_sequence', v_project.construction_phase_sequence,
    'contract_value', v_project.contract_value,
    'client_name', COALESCE(v_project.client_entity, v_project.client_name),
    'job_type', v_project.job_type,
    'project_kind', v_project.project_kind,
    'location', jsonb_build_object(
      'street', v_project.street,
      'city', v_project.city,
      'state', v_project.state,
      'zip', v_project.zip,
      'county', v_project.county,
      'subdivision', v_project.subdivision_name,
      'lot', v_project.lot_number
    )
  );

  -- =============================================
  -- 2. ACTIVE COMMITMENTS (from journal_claims)
  -- =============================================
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'claim_id', jc.claim_id,
      'claim_text', jc.claim_text,
      'speaker_label', jc.speaker_label,
      'epistemic_status', jc.epistemic_status,
      'created_at', jc.created_at
    ) ORDER BY jc.created_at DESC
  ), '[]'::jsonb)
  INTO v_commitments
  FROM journal_claims jc
  WHERE jc.project_id = p_project_id
    AND jc.claim_type = 'commitment'
    AND jc.active = true;

  -- =============================================
  -- 3. OPEN LOOPS
  -- =============================================
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'loop_id', jol.id,
      'loop_type', jol.loop_type,
      'description', jol.description,
      'status', jol.status,
      'created_at', jol.created_at
    ) ORDER BY jol.created_at DESC
  ), '[]'::jsonb)
  INTO v_open_loops
  FROM journal_open_loops jol
  WHERE jol.project_id = p_project_id
    AND jol.status = 'open';

  -- =============================================
  -- 4. RECENT DECISIONS (last 14 days)
  -- =============================================
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'claim_id', jc.claim_id,
      'claim_text', jc.claim_text,
      'speaker_label', jc.speaker_label,
      'epistemic_status', jc.epistemic_status,
      'created_at', jc.created_at
    ) ORDER BY jc.created_at DESC
  ), '[]'::jsonb)
  INTO v_decisions
  FROM journal_claims jc
  WHERE jc.project_id = p_project_id
    AND jc.claim_type = 'decision'
    AND jc.active = true
    AND jc.created_at >= NOW() - INTERVAL '14 days';

  -- =============================================
  -- 5. KEY CONTACTS MENTIONED RECENTLY (last 14 days)
  --    Distinct speaker labels + resolved contact IDs
  -- =============================================
  SELECT COALESCE(jsonb_agg(DISTINCT
    jsonb_build_object(
      'speaker_label', jc.speaker_label,
      'contact_id', jc.speaker_contact_id,
      'is_internal', jc.speaker_is_internal
    )
  ), '[]'::jsonb)
  INTO v_contacts_mentioned
  FROM journal_claims jc
  WHERE jc.project_id = p_project_id
    AND jc.active = true
    AND jc.speaker_label IS NOT NULL
    AND jc.created_at >= NOW() - INTERVAL '14 days';

  -- =============================================
  -- 6. LAST ACTIVITY (most recent claim or interaction)
  -- =============================================
  SELECT GREATEST(
    (SELECT MAX(jc.created_at) FROM journal_claims jc WHERE jc.project_id = p_project_id),
    (SELECT MAX(i.event_at_utc) FROM interactions i WHERE i.project_id = p_project_id)
  )
  INTO v_last_activity;

  -- =============================================
  -- 7. STRIKING SIGNALS (high-striking recent calls for this project)
  -- =============================================
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'interaction_id', ss.interaction_id,
      'striking_score', ss.striking_score,
      'primary_signal_type', ss.primary_signal_type,
      'signals', ss.signals,
      'created_at', ss.created_at
    ) ORDER BY ss.striking_score DESC
  ), '[]'::jsonb)
  INTO v_striking
  FROM striking_signals ss
  JOIN interactions i ON i.interaction_id = ss.interaction_id
  WHERE i.project_id = p_project_id
    AND ss.striking_score >= 0.5;

  -- =============================================
  -- 8. UNRESOLVED CONFLICTS
  -- =============================================
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'conflict_id', jcf.id,
      'conflict_type', jcf.conflict_type,
      'claim_a_id', jcf.claim_a_id,
      'claim_b_id', jcf.claim_b_id,
      'created_at', jcf.created_at
    ) ORDER BY jcf.created_at DESC
  ), '[]'::jsonb)
  INTO v_conflicts
  FROM journal_conflicts jcf
  WHERE jcf.resolved = false
    AND (
      jcf.claim_a_id IN (SELECT claim_id FROM journal_claims WHERE project_id = p_project_id)
      OR jcf.claim_b_id IN (SELECT claim_id FROM journal_claims WHERE project_id = p_project_id)
    );

  -- =============================================
  -- 9. CLAIM TYPE DISTRIBUTION (for the LLM summary input)
  -- =============================================
  SELECT jsonb_object_agg(claim_type, cnt)
  INTO v_claim_counts
  FROM (
    SELECT claim_type, count(*) as cnt
    FROM journal_claims
    WHERE project_id = p_project_id AND active = true
    GROUP BY claim_type
  ) sub;

  -- =============================================
  -- 10. ASSEMBLE
  -- =============================================
  RETURN jsonb_build_object(
    'project_id', p_project_id,
    'snapshot_as_of', NOW(),
    'snapshot_version', 'v1.0.0',
    'system_record', v_system_record,
    'phase', v_phase_name,
    'last_activity', v_last_activity,
    'claim_distribution', COALESCE(v_claim_counts, '{}'::jsonb),
    'active_commitments', v_commitments,
    'open_loops', v_open_loops,
    'recent_decisions', v_decisions,
    'contacts_mentioned', v_contacts_mentioned,
    'striking_signals', v_striking,
    'striking_recent', jsonb_array_length(COALESCE(v_striking, '[]'::jsonb)) > 0,
    'unresolved_conflicts', v_conflicts,
    'record_discrepancies', '[]'::jsonb  -- placeholder for DATA-10 output
  );
END;
$function$;

COMMENT ON FUNCTION public.get_project_state_snapshot(uuid) IS 
  'DATA-12 snapshot RPC: merges journal claims + system records into a per-project state snapshot for context-assembly. v1.0.0';
;
