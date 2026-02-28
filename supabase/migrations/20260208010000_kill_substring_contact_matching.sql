-- Phase 1a: Kill substring matching in contact lookup functions
-- Replace ILIKE '%x%' with exact match + word-boundary-aware matching
-- Part of: phonetic-adjacent-only initiative

-- 1) find_contact_by_name_or_alias: was using ILIKE '%search_term%' (pure substring)
--    Now: exact match on name/alias only (case-insensitive)
CREATE OR REPLACE FUNCTION find_contact_by_name_or_alias(search_term text)
RETURNS TABLE (
    contact_id uuid,
    contact_name text,
    contact_phone text,
    contact_type text,
    company text,
    match_type text,
    matched_value text
) AS $$
BEGIN
    RETURN QUERY
    -- Match on primary name (exact, case-insensitive)
    SELECT
        c.id,
        c.name,
        c.phone,
        c.contact_type,
        c.company,
        'primary_name'::text as match_type,
        c.name as matched_value
    FROM contacts c
    WHERE LOWER(c.name) = LOWER(search_term)

    UNION

    -- Match on any alias (exact, case-insensitive)
    SELECT
        c.id,
        c.name,
        c.phone,
        c.contact_type,
        c.company,
        'alias'::text as match_type,
        alias as matched_value
    FROM contacts c
    CROSS JOIN LATERAL unnest(c.aliases) as alias
    WHERE LOWER(alias) = LOWER(search_term)

    ORDER BY 6, 2;  -- match_type, contact_name (positional for UNION compat)
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION find_contact_by_name_or_alias(text) IS
'Search for contacts by name or any registered alias. Exact match only (no substring).
v2: Removed ILIKE substring matching to prevent false positives on short tokens.
v2.1: Fixed ORDER BY to use positional refs for UNION compatibility.';
-- 2) match_text_to_contact: was using ILIKE '%alias%' (substring in text)
--    Now: word-boundary matching using regexp
CREATE OR REPLACE FUNCTION match_text_to_contact(input_text text)
RETURNS TABLE (
    contact_id uuid,
    contact_name text,
    contact_phone text,
    matched_alias text,
    match_confidence numeric
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.phone,
        alias,
        CASE
            -- Primary name: word-boundary match in text
            WHEN input_text ~* ('\m' || regexp_replace(c.name, '([.*+?^${}()|[\]\\])', '\\\1', 'g') || '\M')
              THEN 1.0
            -- Alias: word-boundary match in text
            WHEN input_text ~* ('\m' || regexp_replace(alias, '([.*+?^${}()|[\]\\])', '\\\1', 'g') || '\M')
              THEN 0.9
            ELSE 0.0
        END as confidence
    FROM contacts c
    CROSS JOIN LATERAL unnest(ARRAY[c.name] || COALESCE(c.aliases, '{}')) as alias
    WHERE
      -- Only match if alias appears as a whole word/phrase in the text
      LENGTH(alias) >= 4
      AND input_text ~* ('\m' || regexp_replace(alias, '([.*+?^${}()|[\]\\])', '\\\1', 'g') || '\M')
    ORDER BY confidence DESC, c.name;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION match_text_to_contact(text) IS
'Given a text string, find contacts whose name or aliases appear as whole words in the text.
v2: Replaced ILIKE substring with word-boundary regex. Min alias length 4.';
