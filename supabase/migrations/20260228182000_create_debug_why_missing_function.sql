-- Migration: create_debug_why_missing_function
-- Applied: 2026-02-28 via gandalf apply_migration
-- Purpose: RPC function for truth-graph debugging.
--          Given a contact_id or interaction_id, diagnoses why data is missing
--          across ingestion, segmentation, attribution, and defect lanes.
--          Returns structured diagnostic rows the Assistant can cite directly.

CREATE OR REPLACE FUNCTION public.debug_why_missing(
  p_contact_id uuid DEFAULT NULL,
  p_interaction_id text DEFAULT NULL
)
RETURNS TABLE (
  check_name text,
  status text,
  detail text,
  lane text,
  pointer text
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Validate: at least one param required
  IF p_contact_id IS NULL AND p_interaction_id IS NULL THEN
    RETURN QUERY SELECT
      'input_error'::text,
      'FAIL'::text,
      'Provide at least one of p_contact_id or p_interaction_id'::text,
      'input'::text,
      NULL::text;
    RETURN;
  END IF;

  -- Check 1: Does the interaction exist?
  RETURN QUERY
  WITH matched AS (
    SELECT i.id, i.interaction_id, i.contact_id, i.project_id,
           i.contact_name, i.channel, i.event_at_utc, i.ingested_at_utc
    FROM interactions i
    WHERE (p_interaction_id IS NOT NULL AND i.interaction_id = p_interaction_id)
       OR (p_contact_id IS NOT NULL AND i.contact_id = p_contact_id)
    ORDER BY COALESCE(i.event_at_utc, i.ingested_at_utc) DESC
    LIMIT 5
  )
  SELECT
    'interaction_exists'::text AS check_name,
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL' END::text AS status,
    CASE WHEN count(*) > 0
      THEN count(*)::text || ' interaction(s) found: ' || string_agg(m.interaction_id, ', ' ORDER BY COALESCE(m.event_at_utc, m.ingested_at_utc) DESC)
      ELSE 'No interactions found for given contact_id/interaction_id'
    END::text AS detail,
    'ingestion'::text AS lane,
    COALESCE(p_interaction_id, p_contact_id::text)::text AS pointer
  FROM matched m;

  -- Check 2: Was it moved to errors?
  RETURN QUERY
  SELECT
    'error_table_check'::text,
    CASE WHEN count(*) > 0 THEN 'FAIL' ELSE 'PASS' END::text,
    CASE WHEN count(*) > 0
      THEN count(*)::text || ' error(s): ' || string_agg(ie.error_reason, '; ' ORDER BY ie.moved_at_utc DESC)
      ELSE 'No error records found'
    END::text,
    'ingestion'::text,
    string_agg(ie.interaction_id, ', ')::text
  FROM interactions_errors ie
  WHERE (p_interaction_id IS NOT NULL AND ie.interaction_id = p_interaction_id)
     OR (p_contact_id IS NOT NULL AND ie.interaction_id IN (
           SELECT i2.interaction_id FROM interactions i2 WHERE i2.contact_id = p_contact_id
         ));

  -- Check 3: Does it have conversation spans?
  RETURN QUERY
  SELECT
    'has_spans'::text,
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL' END::text,
    count(*)::text || ' span(s), ' || count(*) FILTER (WHERE NOT cs.is_superseded)::text || ' active'::text,
    'segmentation'::text,
    string_agg(DISTINCT cs.interaction_id, ', ')::text
  FROM conversation_spans cs
  WHERE (p_interaction_id IS NOT NULL AND cs.interaction_id = p_interaction_id)
     OR (p_contact_id IS NOT NULL AND cs.interaction_id IN (
           SELECT i3.interaction_id FROM interactions i3 WHERE i3.contact_id = p_contact_id
         ));

  -- Check 4: Do spans have attributions?
  RETURN QUERY
  SELECT
    'has_attributions'::text,
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL' END::text,
    count(*)::text || ' attribution(s), ' ||
    count(*) FILTER (WHERE sa.attribution_lock = 'human')::text || ' human-locked, ' ||
    'avg_confidence=' || COALESCE(round(avg(sa.confidence), 3)::text, 'N/A')::text,
    'attribution'::text,
    string_agg(DISTINCT sa.attribution_source, ', ')::text
  FROM conversation_spans cs
  JOIN span_attributions sa ON sa.span_id = cs.id
  WHERE cs.is_superseded = false
    AND ((p_interaction_id IS NOT NULL AND cs.interaction_id = p_interaction_id)
      OR (p_contact_id IS NOT NULL AND cs.interaction_id IN (
            SELECT i4.interaction_id FROM interactions i4 WHERE i4.contact_id = p_contact_id
          )));

  -- Check 5: Any open defect events?
  RETURN QUERY
  SELECT
    'defect_events'::text,
    CASE WHEN count(*) FILTER (WHERE rde.current_status = 'open') > 0 THEN 'FAIL' ELSE 'PASS' END::text,
    count(*)::text || ' defect(s), ' ||
    count(*) FILTER (WHERE rde.current_status = 'open')::text || ' open: ' ||
    COALESCE(string_agg(DISTINCT rde.defect_type || '/' || rde.owner_lane, ', ' ORDER BY rde.defect_type || '/' || rde.owner_lane), 'none')::text,
    COALESCE(string_agg(DISTINCT rde.owner_lane, ', '), 'none')::text,
    string_agg(DISTINCT rde.defect_event_id::text, ', ')::text
  FROM redline_defect_events rde
  WHERE (p_interaction_id IS NOT NULL AND rde.interaction_id = p_interaction_id)
     OR (p_contact_id IS NOT NULL AND rde.interaction_id IN (
           SELECT i5.interaction_id FROM interactions i5 WHERE i5.contact_id = p_contact_id
         ));

  -- Check 6: Truth graph health score
  RETURN QUERY
  SELECT
    'truth_health_score'::text,
    CASE
      WHEN v.truth_health_score >= 70 THEN 'PASS'
      WHEN v.truth_health_score >= 40 THEN 'WARN'
      ELSE 'FAIL'
    END::text,
    'score=' || v.truth_health_score::text ||
    ' spans=' || v.span_count::text ||
    ' attrs=' || v.attribution_count::text ||
    ' defects=' || v.open_defect_count::text::text,
    'overall'::text,
    v.interaction_id::text
  FROM v_truth_graph_summary v
  WHERE (p_interaction_id IS NOT NULL AND v.interaction_id = p_interaction_id)
     OR (p_contact_id IS NOT NULL AND v.contact_id = p_contact_id)
  ORDER BY v.effective_at DESC NULLS LAST
  LIMIT 5;

  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_why_missing(uuid, text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.debug_why_missing IS 'Diagnoses why data is missing from the truth graph. Pass contact_id or interaction_id. Returns diagnostic checks across ingestion, segmentation, attribution, and defect lanes.';
