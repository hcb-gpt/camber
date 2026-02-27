-- scan_transcript_for_projects: street_name aliases are exact-only + require road-context.
--
-- Motivation:
-- - Street names often collide with common words (e.g., "enter" → "enterprise", "red oak" as flooring).
-- - For transcript candidate generation, fuzzy street-name matching is too noisy.
--
-- Policy:
-- - No fuzzy matches for alias_type='street_name' (single or multiword).
-- - street_name exact matches must have road context nearby (rd/road/street/drive/etc).

CREATE OR REPLACE FUNCTION public.scan_transcript_for_projects(
  transcript_text text,
  similarity_threshold double precision DEFAULT 0.4,
  min_alias_length integer DEFAULT 3
)
RETURNS TABLE(
  project_id uuid,
  project_name text,
  matched_term text,
  matched_alias text,
  match_type text,
  score double precision
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_transcript_lower TEXT;
  v_false_cognate_words TEXT[] := ARRAY[
    'windows',
    'between',
    'batten',
    'blank',
    'mason',
    'willing',
    'downstairs',
    'downtown',
    'color', 'colors', 'colour', 'colours'
  ];
BEGIN
  v_transcript_lower := LOWER(transcript_text);
  RETURN QUERY
  WITH alias_candidates AS (
    SELECT pa.project_id AS ac_project_id, p.name AS ac_project_name,
      pa.alias AS ac_alias, pa.alias_type AS ac_alias_type,
      pa.confidence AS ac_confidence, LOWER(pa.alias) AS ac_alias_lower,
      (pa.alias_type = 'client_last_name' AND LENGTH(pa.alias) <= 5) AS ac_is_common,
      (pa.alias_type = 'street_name') AS ac_is_street
    FROM project_aliases pa
    JOIN projects p ON pa.project_id = p.id
    WHERE LENGTH(pa.alias) >= min_alias_length
      AND p.status IN ('active', 'warranty', 'pre-construction')
  ),
  raw_words AS (
    SELECT LOWER(m[1]) AS rw_word
    FROM regexp_matches(transcript_text, '([a-zA-Z][a-zA-Z'']+)', 'g') AS m
    WHERE LENGTH(m[1]) >= min_alias_length
      AND NOT (LOWER(m[1]) = ANY(v_false_cognate_words))
  ),
  transcript_words AS (
    SELECT rw_word AS tw_word, rw_word AS tw_original, 'original'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    UNION
    SELECT regexp_replace(rw_word, '''s$', '') AS tw_word, rw_word AS tw_original,
      'possessive_stripped'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ '''s$'
      AND LENGTH(regexp_replace(rw_word, '''s$', '')) >= min_alias_length
    UNION
    SELECT regexp_replace(rw_word, '(ss|x|z|sh|ch)es$', '\1') AS tw_word,
      rw_word AS tw_original, 'deplural_es'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ '(ss|x|z|sh|ch)es$'
      AND LENGTH(regexp_replace(rw_word, '(ss|x|z|sh|ch)es$', '\1')) >= min_alias_length
    UNION
    SELECT regexp_replace(rw_word, 'ies$', 'y') AS tw_word,
      rw_word AS tw_original, 'deplural_ies'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ 'ies$'
      AND LENGTH(regexp_replace(rw_word, 'ies$', 'y')) >= min_alias_length
    UNION
    SELECT regexp_replace(rw_word, 's$', '') AS tw_word,
      rw_word AS tw_original, 'deplural_s'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ '[^s]s$'
      AND rw_word !~ '''s$'
      AND rw_word !~ 'ies$'
      AND LENGTH(regexp_replace(rw_word, 's$', '')) >= min_alias_length
  ),
  exact_matches AS (
    SELECT ac.ac_project_id, ac.ac_project_name,
      ac.ac_alias AS em_matched_term, ac.ac_alias AS em_matched_alias,
      'exact'::TEXT AS em_match_type, 1.0::DOUBLE PRECISION AS em_score,
      ac.ac_is_common, ac.ac_alias_lower, ac.ac_is_street
    FROM alias_candidates ac
    WHERE v_transcript_lower ~ ('\y' || ac.ac_alias_lower || '\y')
  ),
  fuzzy_single AS (
    SELECT ac.ac_project_id, ac.ac_project_name,
      tw.tw_original AS em_matched_term, ac.ac_alias AS em_matched_alias,
      CASE WHEN tw.tw_variant_type = 'original' THEN 'fuzzy'
           ELSE 'fuzzy_deplural' END::TEXT AS em_match_type,
      (CASE WHEN tw.tw_variant_type = 'original' THEN 1.0 ELSE 0.95 END
        * (0.5 + (similarity(tw.tw_word, ac.ac_alias_lower) - similarity_threshold) * (0.4 / 0.7))
      )::DOUBLE PRECISION AS em_score,
      ac.ac_is_common, ac.ac_alias_lower, tw.tw_start, ac.ac_is_street
    FROM transcript_words tw CROSS JOIN alias_candidates ac
    WHERE ac.ac_alias_lower !~ '\s'
      AND LENGTH(ac.ac_alias_lower) >= 5 AND LENGTH(tw.tw_word) >= 5
      AND similarity(tw.tw_word, ac.ac_alias_lower) >= similarity_threshold
      AND tw.tw_word <> ac.ac_alias_lower
      AND NOT (tw.tw_original = ANY(v_false_cognate_words))
      AND NOT (tw.tw_word = ANY(v_false_cognate_words))
      AND NOT ac.ac_is_street
  ),
  fuzzy_multi AS (
    SELECT ac.ac_project_id, ac.ac_project_name,
      ac.ac_alias AS em_matched_term, ac.ac_alias AS em_matched_alias,
      'fuzzy'::TEXT AS em_match_type,
      (0.5 + (word_similarity(ac.ac_alias_lower, v_transcript_lower) - similarity_threshold) * (0.4 / 0.7))::DOUBLE PRECISION AS em_score,
      ac.ac_is_common, ac.ac_alias_lower, 0 AS tw_start, ac.ac_is_street
    FROM alias_candidates ac
    WHERE ac.ac_alias_lower ~ '\s'
      AND word_similarity(ac.ac_alias_lower, v_transcript_lower) >= 0.5
      AND NOT (v_transcript_lower ~ ('\y' || ac.ac_alias_lower || '\y'))
      AND NOT ac.ac_is_street
  ),
  all_matches AS (
    SELECT ac_project_id, ac_project_name, em_matched_term, em_matched_alias,
      em_match_type, em_score, ac_is_common, ac_alias_lower, ac_is_street,
      strpos(v_transcript_lower, ac_alias_lower) AS am_pos
    FROM exact_matches
    UNION ALL
    SELECT ac_project_id, ac_project_name, em_matched_term, em_matched_alias,
      em_match_type, em_score, ac_is_common, ac_alias_lower, ac_is_street, tw_start AS am_pos
    FROM fuzzy_single
    UNION ALL
    SELECT ac_project_id, ac_project_name, em_matched_term, em_matched_alias,
      em_match_type, em_score, ac_is_common, ac_alias_lower, ac_is_street,
      GREATEST(1, strpos(v_transcript_lower, ac_alias_lower)) AS am_pos
    FROM fuzzy_multi
  ),
  guarded AS (
    SELECT am.ac_project_id, am.ac_project_name, am.em_matched_term,
      am.em_matched_alias, am.em_match_type, am.em_score
    FROM all_matches am
    WHERE
      -- Street-name aliases must include road context near the matched phrase/token.
      (NOT am.ac_is_street OR (
        substring(v_transcript_lower
          FROM GREATEST(1, am.am_pos - 25)
          FOR LENGTH(am.em_matched_term) + 60
        ) ~ '\y(rd|road|st|street|dr|drive|ln|lane|ave|avenue|blvd|boulevard|ct|court|cir|circle|pl|place|pkwy|parkway|way|trl|trail|hwy|highway)\y'
      ))
      AND (
        NOT am.ac_is_common
        OR (am.ac_is_common AND EXISTS (
          SELECT 1 WHERE
            v_transcript_lower ~ ('\y' || am.ac_alias_lower || '''s')
            OR (substring(v_transcript_lower
              FROM GREATEST(1, am.am_pos - 50)
              FOR LENGTH(am.em_matched_term) + 100
            ) ~ '\y(residence|house|project|job|place|property|build|remodel|renovation|bathroom|kitchen)\y')
        ))
      )
  ),
  ranked AS (
    SELECT g.ac_project_id, g.ac_project_name, g.em_matched_term,
      g.em_matched_alias, g.em_match_type, g.em_score,
      ROW_NUMBER() OVER (
        PARTITION BY g.ac_project_id, g.em_matched_alias
        ORDER BY g.em_score DESC,
          CASE g.em_match_type
            WHEN 'exact' THEN 1
            WHEN 'fuzzy' THEN 2
            WHEN 'fuzzy_deplural' THEN 3
          END
      ) AS rn
    FROM guarded g
  )
  SELECT r.ac_project_id, r.ac_project_name, r.em_matched_term,
    r.em_matched_alias, r.em_match_type, r.em_score
  FROM ranked r WHERE r.rn = 1
  ORDER BY r.em_score DESC, r.ac_project_name, r.em_matched_alias;
END;
$function$;
