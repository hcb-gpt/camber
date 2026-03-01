-- Fix: Add get_review_candidates RPC to filter out superseded spans from review swarm.
-- This ensures the runner only processes active spans, matching the SLA monitor.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_review_candidates(p_pool text, p_limit int)
RETURNS TABLE (
  id uuid,
  span_id uuid,
  project_id uuid,
  applied_project_id uuid,
  decision text,
  confidence float8,
  evidence_tier int,
  attribution_source text,
  needs_review boolean,
  conversation_spans jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_pool = 'backlog' THEN
    RETURN QUERY
    SELECT
      sa.id, 
      sa.span_id, 
      sa.project_id, 
      sa.applied_project_id, 
      sa.decision,
      sa.confidence, 
      sa.evidence_tier, 
      sa.attribution_source, 
      sa.needs_review,
      jsonb_build_object(
        'id', cs.id,
        'interaction_id', cs.interaction_id,
        'span_index', cs.span_index,
        'char_start', cs.char_start,
        'char_end', cs.char_end,
        'transcript_segment', cs.transcript_segment
      )
    FROM public.span_attributions sa
    JOIN public.conversation_spans cs ON cs.id = sa.span_id
    WHERE sa.needs_review = true
      AND cs.is_superseded = false
    ORDER BY sa.created_at DESC -- Prioritize newest backlog
    LIMIT p_limit;
  ELSIF p_pool = 'calibration' THEN
    RETURN QUERY
    SELECT
      sa.id, 
      sa.span_id, 
      sa.project_id, 
      sa.applied_project_id, 
      sa.decision,
      sa.confidence, 
      sa.evidence_tier, 
      sa.attribution_source, 
      sa.needs_review,
      jsonb_build_object(
        'id', cs.id,
        'interaction_id', cs.interaction_id,
        'span_index', cs.span_index,
        'char_start', cs.char_start,
        'char_end', cs.char_end,
        'transcript_segment', cs.transcript_segment
      )
    FROM public.span_attributions sa
    JOIN public.conversation_spans cs ON cs.id = sa.span_id
    WHERE sa.needs_review = false
      AND sa.confidence >= 0.55
      AND sa.confidence <= 0.85
      AND cs.is_superseded = false
    ORDER BY sa.created_at DESC
    LIMIT p_limit;
  END IF;
END;
$$;

COMMIT;
