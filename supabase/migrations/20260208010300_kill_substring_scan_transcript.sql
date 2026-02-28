-- Phase 3a: Kill substring matching in scan_transcript_for_projects
-- Replace LIKE '%alias%' with word-boundary regex only
-- Part of: phonetic-adjacent-only initiative

CREATE OR REPLACE FUNCTION scan_transcript_for_projects(
  transcript_text TEXT,
  similarity_threshold DOUBLE PRECISION DEFAULT 0.4,
  min_alias_length INTEGER DEFAULT 4
)
RETURNS TABLE(
  project_id UUID,
  project_name TEXT,
  matched_term TEXT,
  matched_alias TEXT,
  match_type TEXT,
  score DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_transcript_lower TEXT;
BEGIN
  -- Normalize transcript for matching
  v_transcript_lower := LOWER(transcript_text);

  -- For each alias, check if it appears as a whole word in transcript
  RETURN QUERY
  WITH alias_candidates AS (
    SELECT
      pa.project_id,
      p.name as project_name,
      pa.alias,
      pa.alias_type,
      pa.confidence
    FROM project_aliases pa
    JOIN projects p ON pa.project_id = p.id
    WHERE LENGTH(pa.alias) >= min_alias_length
      AND p.status IN ('active', 'warranty', 'pre-construction')
  )
  SELECT DISTINCT ON (ac.project_id, ac.alias)
    ac.project_id,
    ac.project_name,
    ac.alias as matched_term,
    ac.alias as matched_alias,
    -- Only word-boundary match (no more substring fallback)
    'exact'::TEXT as match_type,
    1.0::DOUBLE PRECISION as score
  FROM alias_candidates ac
  WHERE
    -- Word-boundary match only (\y = word boundary in Postgres regex)
    v_transcript_lower ~ ('\y' || LOWER(ac.alias) || '\y')
  ORDER BY ac.project_id, ac.alias;
END;
$function$;
COMMENT ON FUNCTION scan_transcript_for_projects IS
'Scans transcript for known project aliases. Direction: aliases -> transcript.
v2: Removed substring fallback (LIKE). Word-boundary regex only (\y).
Part of phonetic-adjacent-only initiative.';
