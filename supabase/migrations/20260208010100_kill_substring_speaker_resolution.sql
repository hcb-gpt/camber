-- Phase 1b: Kill substring matching in speaker resolution functions
-- Remove "contains" and "partial" match paths; keep exact, prefix, and phonetic
-- Part of: phonetic-adjacent-only initiative

-- 1) resolve_transcript_speakers: remove ILIKE substring paths
CREATE OR REPLACE FUNCTION resolve_transcript_speakers(transcript_text TEXT)
RETURNS TABLE(
  speaker_name TEXT,
  contact_id UUID,
  contact_name TEXT,
  contact_type TEXT,
  project_count INT,
  is_floater BOOLEAN,
  affiliated_project_ids UUID[]
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
  RETURN QUERY
  WITH speakers AS (
    SELECT e.speaker_name
    FROM extract_speakers_from_transcript(transcript_text) e
  ),
  resolved AS (
    SELECT DISTINCT ON (s.speaker_name)
      s.speaker_name,
      c.id as contact_id,
      c.name as contact_name,
      c.contact_type,
      CASE
        -- Exact name match (highest)
        WHEN LOWER(c.name) = LOWER(s.speaker_name) THEN 100
        -- Exact alias match
        WHEN EXISTS (
          SELECT 1 FROM unnest(c.aliases) alias
          WHERE LOWER(alias) = LOWER(s.speaker_name)
        ) THEN 95
        -- Name starts with speaker (prefix only, not substring)
        WHEN c.name ILIKE s.speaker_name || '%' THEN 90
        -- Last name exact match + first name phonetic
        WHEN SPLIT_PART(c.name, ' ', 2) != ''
          AND LOWER(SPLIT_PART(c.name, ' ', 2)) = LOWER(SPLIT_PART(s.speaker_name, ' ', 2))
          AND (
            LOWER(SPLIT_PART(c.name, ' ', 1)) = LOWER(SPLIT_PART(s.speaker_name, ' ', 1))
            OR dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(SPLIT_PART(s.speaker_name, ' ', 1))
          )
          THEN 80
        -- Trigram similarity (whole name, high threshold)
        WHEN similarity(c.name, s.speaker_name) > 0.6 THEN 70
        ELSE 0
      END as match_quality
    FROM speakers s
    LEFT JOIN contacts c ON
      LOWER(c.name) = LOWER(s.speaker_name)
      OR c.name ILIKE s.speaker_name || '%'
      OR (
        SPLIT_PART(c.name, ' ', 2) != ''
        AND LOWER(SPLIT_PART(c.name, ' ', 2)) = LOWER(SPLIT_PART(s.speaker_name, ' ', 2))
        AND (
          LOWER(SPLIT_PART(c.name, ' ', 1)) = LOWER(SPLIT_PART(s.speaker_name, ' ', 1))
          OR dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(SPLIT_PART(s.speaker_name, ' ', 1))
        )
      )
      OR similarity(c.name, s.speaker_name) > 0.6
      -- Exact alias match only (no substring)
      OR EXISTS (
        SELECT 1 FROM unnest(c.aliases) alias
        WHERE LOWER(alias) = LOWER(s.speaker_name)
      )
    WHERE c.contact_type IN ('internal', 'client', 'subcontractor', 'vendor') OR c.id IS NULL
    ORDER BY s.speaker_name, match_quality DESC
  ),
  with_affinities AS (
    SELECT
      r.speaker_name,
      r.contact_id,
      r.contact_name,
      r.contact_type,
      COUNT(DISTINCT cpa.project_id)::INT as project_count,
      COUNT(DISTINCT cpa.project_id) > 1 as is_floater,
      ARRAY_AGG(DISTINCT cpa.project_id) FILTER (WHERE cpa.project_id IS NOT NULL) as affiliated_project_ids
    FROM resolved r
    LEFT JOIN correspondent_project_affinity cpa ON r.contact_id = cpa.contact_id
    GROUP BY r.speaker_name, r.contact_id, r.contact_name, r.contact_type
  )
  SELECT
    wa.speaker_name,
    wa.contact_id,
    wa.contact_name,
    wa.contact_type,
    wa.project_count,
    wa.is_floater,
    wa.affiliated_project_ids
  FROM with_affinities wa
  ORDER BY wa.project_count DESC;
END;
$function$;
COMMENT ON FUNCTION resolve_transcript_speakers IS
'Resolves speaker labels to contacts. Checks aliases for exact match only.
v3: Removed all ILIKE substring matching (partial alias, contains paths).
    Added phonetic matching via dmetaphone for first-name when last-name matches exactly.';
-- 2) resolve_speaker_contact: remove partial alias, contains paths
CREATE OR REPLACE FUNCTION resolve_speaker_contact(
  p_speaker_label TEXT,
  p_project_id UUID DEFAULT NULL
)
RETURNS TABLE (
  contact_id UUID,
  contact_name TEXT,
  is_internal BOOLEAN,
  match_quality INT,
  match_type TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_label_lower TEXT;
  v_first_name TEXT;
  v_last_name TEXT;
BEGIN
  IF p_speaker_label IS NULL OR TRIM(p_speaker_label) = '' THEN
    RETURN;
  END IF;

  v_label_lower := LOWER(TRIM(p_speaker_label));
  v_first_name := LOWER(SPLIT_PART(p_speaker_label, ' ', 1));
  v_last_name := LOWER(SPLIT_PART(p_speaker_label, ' ', 2));

  RETURN QUERY
  WITH matches AS (
    SELECT
      c.id,
      c.name,
      (c.contact_type = 'internal') as is_internal,
      CASE
        -- Exact name match (highest)
        WHEN LOWER(c.name) = v_label_lower THEN 100
        -- Exact alias match
        WHEN EXISTS (
          SELECT 1 FROM unnest(c.aliases) AS alias
          WHERE LOWER(alias) = v_label_lower
        ) THEN 95
        -- First + last name exact match
        WHEN v_last_name != ''
          AND LOWER(SPLIT_PART(c.name, ' ', 1)) = v_first_name
          AND LOWER(SPLIT_PART(c.name, ' ', 2)) = v_last_name THEN 90
        -- Last name exact + first name phonetic (e.g., Zack/Zachary)
        WHEN v_last_name != '' AND LENGTH(v_first_name) >= 4
          AND LOWER(SPLIT_PART(c.name, ' ', 2)) = v_last_name
          AND dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(v_first_name)
          THEN 80
        -- First + last both phonetic match (both names must match)
        WHEN v_last_name != '' AND LENGTH(v_first_name) >= 4 AND LENGTH(v_last_name) >= 4
          AND dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(v_first_name)
          AND dmetaphone(SPLIT_PART(c.name, ' ', 2)) = dmetaphone(v_last_name)
          THEN 75
        -- First name prefix match (name starts with, min 4 chars)
        WHEN LENGTH(v_first_name) >= 4
          AND LOWER(c.name) LIKE v_first_name || '%' THEN 70
        ELSE 0
      END as match_quality,
      CASE
        WHEN LOWER(c.name) = v_label_lower THEN 'exact_name'
        WHEN EXISTS (
          SELECT 1 FROM unnest(c.aliases) AS alias
          WHERE LOWER(alias) = v_label_lower
        ) THEN 'exact_alias'
        WHEN v_last_name != ''
          AND LOWER(SPLIT_PART(c.name, ' ', 1)) = v_first_name
          AND LOWER(SPLIT_PART(c.name, ' ', 2)) = v_last_name THEN 'exact_full_name'
        WHEN v_last_name != '' AND LENGTH(v_first_name) >= 4
          AND LOWER(SPLIT_PART(c.name, ' ', 2)) = v_last_name
          AND dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(v_first_name)
          THEN 'phonetic_first_exact_last'
        WHEN v_last_name != '' AND LENGTH(v_first_name) >= 4 AND LENGTH(v_last_name) >= 4
          AND dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(v_first_name)
          AND dmetaphone(SPLIT_PART(c.name, ' ', 2)) = dmetaphone(v_last_name)
          THEN 'phonetic_both'
        WHEN LENGTH(v_first_name) >= 4
          AND LOWER(c.name) LIKE v_first_name || '%' THEN 'first_name_prefix'
        ELSE 'none'
      END as match_type
    FROM contacts c
    WHERE
      -- Only consider contacts that could match (no substring scans)
      LOWER(c.name) = v_label_lower
      OR EXISTS (
        SELECT 1 FROM unnest(c.aliases) AS alias
        WHERE LOWER(alias) = v_label_lower
      )
      -- First+last exact components
      OR (v_last_name != ''
        AND LOWER(SPLIT_PART(c.name, ' ', 2)) = v_last_name
        AND (
          LOWER(SPLIT_PART(c.name, ' ', 1)) = v_first_name
          OR (LENGTH(v_first_name) >= 4 AND dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(v_first_name))
        )
      )
      -- Both phonetic
      OR (v_last_name != '' AND LENGTH(v_first_name) >= 4 AND LENGTH(v_last_name) >= 4
        AND dmetaphone(SPLIT_PART(c.name, ' ', 1)) = dmetaphone(v_first_name)
        AND dmetaphone(SPLIT_PART(c.name, ' ', 2)) = dmetaphone(v_last_name)
      )
      -- First name prefix
      OR (LENGTH(v_first_name) >= 4 AND LOWER(c.name) LIKE v_first_name || '%')
  ),
  ranked AS (
    SELECT
      m.*,
      COALESCE(
        (SELECT cpa.weight * 10
         FROM correspondent_project_affinity cpa
         WHERE cpa.contact_id = m.id
           AND cpa.project_id = p_project_id),
        0
      ) as affinity_boost
    FROM matches m
    WHERE m.match_quality > 0
  )
  SELECT
    r.id as contact_id,
    r.name as contact_name,
    r.is_internal,
    r.match_quality,
    r.match_type
  FROM ranked r
  ORDER BY (r.match_quality + r.affinity_boost) DESC, r.is_internal DESC
  LIMIT 1;
END;
$$;
COMMENT ON FUNCTION resolve_speaker_contact IS
'Resolves a speaker label to a contact_id with is_internal flag.
v2: Removed all substring matching (partial_alias, first_name_contains, last_name_contains).
    Added phonetic matching via dmetaphone: requires last-name exact + first-name phonetic,
    or both first+last phonetic (min 4 chars each). First-name-only never promotes to match.
    Min first-name length raised from 3 to 4.';
