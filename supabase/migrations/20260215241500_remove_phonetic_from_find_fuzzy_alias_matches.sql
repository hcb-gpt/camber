-- find_fuzzy_alias_matches: remove phonetic matching (soundex/dmetaphone).
--
-- Rationale:
-- - Phonetic matching causes high false-positive rates in transcript contexts.
-- - Deterministic lane should be exact + prefix + pg_trgm + small edit-distance only.

CREATE OR REPLACE FUNCTION public.find_fuzzy_alias_matches(
  search_term TEXT,
  similarity_threshold FLOAT DEFAULT 0.3,
  levenshtein_max INT DEFAULT 2
)
RETURNS TABLE(
  project_id UUID,
  project_name TEXT,
  alias TEXT,
  match_type TEXT,
  score FLOAT
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  RETURN QUERY
  WITH matches AS (
    SELECT
      pa.project_id,
      p.name as project_name,
      pa.alias,
      CASE
        WHEN LOWER(pa.alias) = LOWER(search_term) THEN 'exact'
        WHEN LOWER(pa.alias) LIKE LOWER(search_term) || '%' THEN 'prefix'
        WHEN LENGTH(search_term) > 3
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= similarity_threshold THEN 'trigram'
        WHEN LENGTH(search_term) > 3
          AND levenshtein(LOWER(pa.alias), LOWER(search_term)) <= levenshtein_max THEN 'levenshtein'
        ELSE NULL
      END as match_type,
      CASE
        WHEN LOWER(pa.alias) = LOWER(search_term) THEN 1.0
        WHEN LOWER(pa.alias) LIKE LOWER(search_term) || '%' THEN 0.95
        WHEN LENGTH(search_term) > 3
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= similarity_threshold
          THEN similarity(LOWER(pa.alias), LOWER(search_term))
        WHEN LENGTH(search_term) > 3
          AND levenshtein(LOWER(pa.alias), LOWER(search_term)) <= levenshtein_max
          THEN 1.0 - (levenshtein(LOWER(pa.alias), LOWER(search_term))::FLOAT / 5.0)
        ELSE 0
      END as score
    FROM project_aliases pa
    JOIN projects p ON pa.project_id = p.id
    WHERE
      LOWER(pa.alias) = LOWER(search_term)
      OR LOWER(pa.alias) LIKE LOWER(search_term) || '%'
      OR (LENGTH(search_term) > 3 AND pa.alias % search_term)
  )
  SELECT m.project_id, m.project_name, m.alias, m.match_type, m.score
  FROM matches m
  WHERE m.match_type IS NOT NULL
  ORDER BY m.score DESC, m.alias;
END;
$$;
COMMENT ON FUNCTION public.find_fuzzy_alias_matches(TEXT, FLOAT, INT) IS
'Find project aliases matching a search term using deterministic strategies only (exact, prefix, pg_trgm, levenshtein).\n\nPhonetic matching (soundex/dmetaphone) is intentionally disabled due to common-word collision risk.';
