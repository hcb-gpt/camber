-- scan_transcript_for_projects: remove phonetic matching (soundex/dmetaphone)
-- and add a small, evidence-based false-cognate stoplist for fuzzy paths only.
--
-- Rationale:
-- - Phonetic matching produces unacceptable collisions with common English words.
-- - A tiny stoplist blocks proven collision tokens without suppressing legitimate matches
--   like "permit" → Permar (fuzzy cross-reference).
--
-- Evidence (examples observed in production transcripts):
-- - "downstairs" → "downs" (Hurley) via fuzzy_deplural (~0.50) — false positive
-- - "windows" → "Windship" via phonetic (historical) — false positive

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
  -- False-cognate tokens observed to collide with project aliases on fuzzy paths.
  -- This list is intentionally minimal; it must stay evidence-based.
  v_false_cognate_words TEXT[] := ARRAY[
    'windows',
    'between',
    'batten',
    'blank',
    'mason',
    'willing',
    'downstairs',
    'color', 'colors', 'colour', 'colours'
  ];
BEGIN
  v_transcript_lower := LOWER(transcript_text);
  RETURN QUERY
  WITH alias_candidates AS (
    SELECT pa.project_id AS ac_project_id, p.name AS ac_project_name,
      pa.alias AS ac_alias, pa.alias_type AS ac_alias_type,
      pa.confidence AS ac_confidence, LOWER(pa.alias) AS ac_alias_lower,
      (pa.alias_type = 'client_last_name' AND LENGTH(pa.alias) <= 5) AS ac_is_common
    FROM project_aliases pa
    JOIN projects p ON pa.project_id = p.id
    WHERE LENGTH(pa.alias) >= min_alias_length
      AND p.status IN ('active', 'warranty', 'pre-construction')
  ),
  -- Extract words from transcript, then generate depluralized variants.
  -- Note: false-cognate stoplist is applied ONLY to fuzzy paths (exact matching is separate).
  raw_words AS (
    SELECT LOWER(m[1]) AS rw_word
    FROM regexp_matches(transcript_text, '([a-zA-Z][a-zA-Z'']+)', 'g') AS m
    WHERE LENGTH(m[1]) >= min_alias_length
      AND NOT (LOWER(m[1]) = ANY(v_false_cognate_words))
  ),
  transcript_words AS (
    -- Original word
    SELECT rw_word AS tw_word, rw_word AS tw_original, 'original'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    UNION
    -- Depluralized: strip possessive 's  (e.g., "skelton's" -> "skelton")
    SELECT regexp_replace(rw_word, '''s$', '') AS tw_word, rw_word AS tw_original,
      'possessive_stripped'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ '''s$'
      AND LENGTH(regexp_replace(rw_word, '''s$', '')) >= min_alias_length
    UNION
    -- Depluralized: strip trailing "es" for words ending in "ses","xes","zes","shes","ches"
    -- e.g., "mosses" -> "moss", "foxes" -> "fox"
    SELECT regexp_replace(rw_word, '(ss|x|z|sh|ch)es$', '\1') AS tw_word,
      rw_word AS tw_original, 'deplural_es'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ '(ss|x|z|sh|ch)es$'
      AND LENGTH(regexp_replace(rw_word, '(ss|x|z|sh|ch)es$', '\1')) >= min_alias_length
    UNION
    -- Depluralized: strip trailing "ies" -> "y" (e.g., "hurries" -> "hurry")
    SELECT regexp_replace(rw_word, 'ies$', 'y') AS tw_word,
      rw_word AS tw_original, 'deplural_ies'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ 'ies$'
      AND LENGTH(regexp_replace(rw_word, 'ies$', 'y')) >= min_alias_length
    UNION
    -- Depluralized: strip simple trailing "s" (e.g., "skeletons" -> "skeleton", "hurleys" -> "hurley")
    SELECT regexp_replace(rw_word, 's$', '') AS tw_word,
      rw_word AS tw_original, 'deplural_s'::TEXT AS tw_variant_type,
      strpos(v_transcript_lower, rw_word) AS tw_start
    FROM raw_words
    WHERE rw_word ~ '[^s]s$'  -- ends in s but not ss (handled above)
      AND rw_word !~ '''s$'   -- not possessive (handled above)
      AND rw_word !~ 'ies$'   -- not ies plural (handled above)
      AND LENGTH(regexp_replace(rw_word, 's$', '')) >= min_alias_length
  ),
  exact_matches AS (
    SELECT ac.ac_project_id, ac.ac_project_name,
      ac.ac_alias AS em_matched_term, ac.ac_alias AS em_matched_alias,
      'exact'::TEXT AS em_match_type, 1.0::DOUBLE PRECISION AS em_score,
      ac.ac_is_common, ac.ac_alias_lower
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
      ac.ac_is_common, ac.ac_alias_lower, tw.tw_start
    FROM transcript_words tw CROSS JOIN alias_candidates ac
    WHERE ac.ac_alias_lower !~ '\s'
      AND LENGTH(ac.ac_alias_lower) >= 5 AND LENGTH(tw.tw_word) >= 5
      AND similarity(tw.tw_word, ac.ac_alias_lower) >= similarity_threshold
      AND tw.tw_word <> ac.ac_alias_lower
  ),
  fuzzy_multi AS (
    SELECT ac.ac_project_id, ac.ac_project_name,
      ac.ac_alias AS em_matched_term, ac.ac_alias AS em_matched_alias,
      'fuzzy'::TEXT AS em_match_type,
      (0.5 + (word_similarity(ac.ac_alias_lower, v_transcript_lower) - similarity_threshold) * (0.4 / 0.7))::DOUBLE PRECISION AS em_score,
      ac.ac_is_common, ac.ac_alias_lower, 0 AS tw_start
    FROM alias_candidates ac
    WHERE ac.ac_alias_lower ~ '\s'
      AND word_similarity(ac.ac_alias_lower, v_transcript_lower) >= 0.5
      AND NOT (v_transcript_lower ~ ('\y' || ac.ac_alias_lower || '\y'))
  ),
  all_matches AS (
    SELECT ac_project_id, ac_project_name, em_matched_term, em_matched_alias,
      em_match_type, em_score, ac_is_common, ac_alias_lower,
      strpos(v_transcript_lower, ac_alias_lower) AS am_pos
    FROM exact_matches
    UNION ALL
    SELECT ac_project_id, ac_project_name, em_matched_term, em_matched_alias,
      em_match_type, em_score, ac_is_common, ac_alias_lower, tw_start AS am_pos
    FROM fuzzy_single
    UNION ALL
    SELECT ac_project_id, ac_project_name, em_matched_term, em_matched_alias,
      em_match_type, em_score, ac_is_common, ac_alias_lower,
      GREATEST(1, strpos(v_transcript_lower, ac_alias_lower)) AS am_pos
    FROM fuzzy_multi
  ),
  guarded AS (
    SELECT am.ac_project_id, am.ac_project_name, am.em_matched_term,
      am.em_matched_alias, am.em_match_type, am.em_score
    FROM all_matches am
    WHERE NOT am.ac_is_common
      OR (am.ac_is_common AND EXISTS (
        SELECT 1 WHERE
          v_transcript_lower ~ ('\y' || am.ac_alias_lower || '''s')
          OR (substring(v_transcript_lower
            FROM GREATEST(1, am.am_pos - 50)
            FOR LENGTH(am.em_matched_term) + 100
          ) ~ '\y(residence|house|project|job|place|property|build|remodel|renovation|bathroom|kitchen)\y')
      ))
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
COMMENT ON FUNCTION public.scan_transcript_for_projects(text, double precision, integer) IS
'Scans transcript for project aliases using word-boundary exact matches and pg_trgm fuzzy matching (with depluralization variants).\n\nPhonetic matching (soundex/dmetaphone) is intentionally disabled due to common-word collision risk.\n\nIncludes a small, evidence-based false-cognate stoplist that applies to fuzzy paths only (exact matches remain eligible).';
