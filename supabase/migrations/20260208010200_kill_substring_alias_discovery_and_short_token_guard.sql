-- Phase 1c + Phase 2: Kill substring in alias discovery + short-token guard
-- Part of: phonetic-adjacent-only initiative

-- 1) suggest_alias_additions: replace ILIKE '%word%' with exact component matching
CREATE OR REPLACE FUNCTION suggest_alias_additions(sample_text text)
RETURNS TABLE (
    contact_id uuid,
    contact_name text,
    current_aliases text[],
    potential_new_alias text,
    match_context text,
    recommendation text
)
SET search_path = public
AS $$
DECLARE
    words text[];
    word text;
BEGIN
    -- Extract capitalized words that might be names (min length 4, was 2)
    words := ARRAY(
        SELECT DISTINCT match[1]
        FROM regexp_matches(sample_text, '\m([A-Z][a-z]+)\M', 'g') as match
        WHERE length(match[1]) >= 4
    );

    RETURN QUERY
    WITH potential_matches AS (
        SELECT
            c.id,
            c.name,
            c.aliases,
            w.word as candidate,
            CASE
                -- Exact match on first or last name component (not substring)
                WHEN LOWER(SPLIT_PART(c.name, ' ', 1)) = LOWER(w.word) THEN 'exact_first_name'
                WHEN LOWER(SPLIT_PART(c.name, ' ', 2)) = LOWER(w.word) THEN 'exact_last_name'
                WHEN w.word ILIKE ANY(c.aliases) THEN 'already_alias'
                -- Levenshtein on name components (not substring)
                WHEN LENGTH(w.word) >= 4
                  AND levenshtein(lower(w.word), lower(split_part(c.name, ' ', 1))) <= 2
                  THEN 'fuzzy_first'
                WHEN LENGTH(w.word) >= 4
                  AND levenshtein(lower(w.word), lower(split_part(c.name, ' ', 2))) <= 2
                  THEN 'fuzzy_last'
                ELSE NULL
            END as match_type
        FROM contacts c
        CROSS JOIN unnest(words) as w(word)
        WHERE c.contact_type NOT IN ('spam')
    )
    SELECT
        pm.id,
        pm.name,
        pm.aliases,
        pm.candidate,
        pm.match_type,
        CASE
            WHEN pm.match_type = 'already_alias' THEN 'Already tracked'
            WHEN pm.match_type IN ('exact_first_name', 'exact_last_name') THEN 'Consider adding as alias'
            WHEN pm.match_type IN ('fuzzy_first', 'fuzzy_last') THEN 'Possible misspelling - review'
            ELSE 'No action'
        END as rec
    FROM potential_matches pm
    WHERE pm.match_type IS NOT NULL
    AND pm.match_type != 'already_alias'
    ORDER BY pm.name, pm.candidate;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION suggest_alias_additions(text) IS
'Analyzes sample text to suggest potential new aliases based on fuzzy matching.
v2: Removed ILIKE substring matching. Now uses exact component match or Levenshtein (min 4 chars).';
-- 2) check_alias_collision: replace ILIKE '%x%' with exact match
CREATE OR REPLACE FUNCTION check_alias_collision(proposed_alias text)
RETURNS TABLE (
    contact_name text,
    contact_type text,
    match_source text
)
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    -- Exact match on primary name
    SELECT c.name, c.contact_type, 'primary_name'::text
    FROM contacts c
    WHERE LOWER(c.name) = LOWER(proposed_alias)
       OR LOWER(SPLIT_PART(c.name, ' ', 1)) = LOWER(proposed_alias)
       OR LOWER(SPLIT_PART(c.name, ' ', 2)) = LOWER(proposed_alias)
    UNION ALL
    -- Exact match on existing alias
    SELECT c.name, c.contact_type, 'alias'::text
    FROM contacts c, unnest(c.aliases) as a
    WHERE LOWER(a) = LOWER(proposed_alias)
    UNION ALL
    -- Exact match on company alias
    SELECT c.name, c.contact_type, 'company_alias'::text
    FROM contacts c, unnest(c.company_aliases) as ca
    WHERE LOWER(ca) = LOWER(proposed_alias);
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION check_alias_collision(text) IS
'Before adding a new alias, check if it would collide with existing contacts.
v2: Exact match only (no substring). Checks name components individually.';
-- 3) Phase 2: Short-token guard on find_fuzzy_alias_matches phonetic paths
-- Add LENGTH(search_term) > 3 guard to soundex/metaphone paths
CREATE OR REPLACE FUNCTION find_fuzzy_alias_matches(
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
AS $$
BEGIN
  -- Short-token guard: skip phonetic matching entirely for tokens <= 3 chars
  -- Exact and prefix matches still allowed for short tokens
  RETURN QUERY
  WITH matches AS (
    SELECT
      pa.project_id,
      p.name as project_name,
      pa.alias,
      CASE
        WHEN LOWER(pa.alias) = LOWER(search_term) THEN 'exact'
        WHEN LOWER(pa.alias) LIKE LOWER(search_term) || '%' THEN 'prefix'
        -- All fuzzy/phonetic paths require token length > 3
        WHEN LENGTH(search_term) > 3
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= similarity_threshold THEN 'trigram'
        WHEN LENGTH(search_term) > 3
          AND levenshtein(LOWER(pa.alias), LOWER(search_term)) <= levenshtein_max THEN 'levenshtein'
        -- SOUNDEX: length > 3 + length similarity + trigram gate
        WHEN LENGTH(search_term) > 3
          AND soundex(pa.alias) = soundex(search_term)
          AND ABS(LENGTH(pa.alias) - LENGTH(search_term)) <= GREATEST(LENGTH(pa.alias), LENGTH(search_term)) * 0.5
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= 0.2
          THEN 'soundex'
        -- METAPHONE: same constraints
        WHEN LENGTH(search_term) > 3
          AND dmetaphone(pa.alias) = dmetaphone(search_term)
          AND ABS(LENGTH(pa.alias) - LENGTH(search_term)) <= GREATEST(LENGTH(pa.alias), LENGTH(search_term)) * 0.5
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= 0.2
          THEN 'metaphone'
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
        WHEN LENGTH(search_term) > 3
          AND soundex(pa.alias) = soundex(search_term)
          AND ABS(LENGTH(pa.alias) - LENGTH(search_term)) <= GREATEST(LENGTH(pa.alias), LENGTH(search_term)) * 0.5
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= 0.2
          THEN 0.5
        WHEN LENGTH(search_term) > 3
          AND dmetaphone(pa.alias) = dmetaphone(search_term)
          AND ABS(LENGTH(pa.alias) - LENGTH(search_term)) <= GREATEST(LENGTH(pa.alias), LENGTH(search_term)) * 0.5
          AND similarity(LOWER(pa.alias), LOWER(search_term)) >= 0.2
          THEN 0.45
        ELSE 0
      END as score
    FROM project_aliases pa
    JOIN projects p ON pa.project_id = p.id
    WHERE
      -- Quick filter: exact/prefix always checked
      LOWER(pa.alias) = LOWER(search_term)
      OR LOWER(pa.alias) LIKE LOWER(search_term) || '%'
      -- Fuzzy/phonetic filters only for tokens > 3 chars
      OR (LENGTH(search_term) > 3 AND pa.alias % search_term)
      OR (LENGTH(search_term) > 3 AND soundex(pa.alias) = soundex(search_term))
      OR (LENGTH(search_term) > 3 AND dmetaphone(pa.alias) = dmetaphone(search_term))
  )
  SELECT m.project_id, m.project_name, m.alias, m.match_type, m.score
  FROM matches m
  WHERE m.match_type IS NOT NULL
  ORDER BY m.score DESC, m.alias;
END;
$$;
COMMENT ON FUNCTION find_fuzzy_alias_matches IS
'Find project aliases matching a search term using multiple strategies.
v3: Added short-token guard (LENGTH > 3) on all fuzzy/phonetic paths.
    Tokens <= 3 chars (mad, bob, bid, well) only match via exact or prefix.
    Soundex/metaphone still gated by length similarity + trigram >= 0.2.';
