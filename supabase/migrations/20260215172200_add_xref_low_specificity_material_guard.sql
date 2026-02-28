-- Add a deterministic low-specificity guard for semantic xref lookups.
-- Goal: prevent color/material-only query hints from elevating cross-project matches.
--
-- Design:
-- - Extend xref_search_journal_claims with optional `query_hint_text`.
-- - If query_hint_text is low-specificity (material/color terms + generic words only)
--   and no explicit scope is provided, constrain results to a single best project.
-- - Calls that provide scope_contact_id or scope_phone are not constrained by this guard.

DROP FUNCTION IF EXISTS public.xref_search_journal_claims(
  extensions.vector(1536), uuid, text, integer, double precision
);
CREATE FUNCTION public.xref_search_journal_claims(
  query_embedding extensions.vector(1536),
  scope_contact_id uuid DEFAULT NULL,
  scope_phone text DEFAULT NULL,
  result_limit integer DEFAULT 10,
  max_distance double precision DEFAULT 0.5,
  query_hint_text text DEFAULT NULL
)
RETURNS TABLE(
  project_id uuid,
  claim_id uuid,
  distance double precision,
  score double precision,
  claim_text text,
  claim_type text,
  search_text text,
  call_id text,
  speaker_label text,
  epistemic_status text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_low_specificity_query boolean := false;
BEGIN
  IF query_hint_text IS NOT NULL AND btrim(query_hint_text) <> '' THEN
    WITH query_tokens AS (
      SELECT array_remove(regexp_split_to_array(lower(query_hint_text), '[^a-z0-9]+'), '') AS tokens
    ),
    token_profile AS (
      SELECT
        tokens,
        EXISTS (
          SELECT 1
          FROM unnest(tokens) AS t
          WHERE t = ANY (ARRAY[
            'white', 'black', 'gray', 'grey', 'beige', 'cream', 'tan', 'brown',
            'blue', 'green', 'red', 'mystery',
            'marble', 'granite', 'quartz', 'quartzite', 'stone', 'tile', 'slab', 'slabs',
            'countertop', 'countertops', 'material', 'materials', 'color', 'colour', 'paint'
          ]::text[])
        ) AS has_material_or_color,
        COALESCE((
          SELECT bool_and(
            t = ANY (ARRAY[
              'a', 'an', 'and', 'any', 'by', 'color', 'colour', 'colors', 'colours',
              'countertop', 'countertops', 'customer', 'customers', 'for', 'from',
              'in', 'is', 'it', 'material', 'materials', 'marble', 'mystery', 'needs',
              'need', 'of', 'on', 'picked', 'project', 'purchase', 'selected', 'selection',
              'slab', 'slabs', 'some', 'stone', 'the', 'their', 'this', 'tile', 'to', 'two',
              'was', 'were', 'white', 'with'
            ]::text[])
          )
          FROM unnest(tokens) AS t
        ), false) AS all_tokens_low_signal
      FROM query_tokens
    )
    SELECT
      (cardinality(tokens) > 0) AND has_material_or_color AND all_tokens_low_signal
    INTO v_low_specificity_query
    FROM token_profile;
  END IF;

  RETURN QUERY
  WITH base_results AS (
    SELECT
      jc.project_id,
      jc.id AS claim_id,
      (jc.embedding <=> query_embedding)::double precision AS distance,
      (1.0 - (jc.embedding <=> query_embedding))::double precision AS score,
      jc.claim_text,
      jc.claim_type,
      jc.search_text,
      jc.call_id,
      jc.speaker_label,
      jc.epistemic_status,
      jc.created_at
    FROM journal_claims jc
    WHERE
      jc.embedding IS NOT NULL
      AND jc.active = true
      AND jc.project_id IS NOT NULL
      AND (scope_contact_id IS NULL OR jc.speaker_contact_id = scope_contact_id)
      AND (scope_phone IS NULL OR EXISTS (
        SELECT 1 FROM calls_raw cr
        WHERE cr.interaction_id = jc.call_id
          AND (cr.other_party_phone = scope_phone OR cr.owner_phone = scope_phone)
      ))
      AND (jc.embedding <=> query_embedding) <= max_distance
  ),
  top_project AS (
    SELECT br.project_id
    FROM base_results br
    GROUP BY br.project_id
    ORDER BY MAX(br.score) DESC, MIN(br.distance) ASC, br.project_id
    LIMIT 1
  )
  SELECT
    br.project_id,
    br.claim_id,
    br.distance,
    br.score,
    br.claim_text,
    br.claim_type,
    br.search_text,
    br.call_id,
    br.speaker_label,
    br.epistemic_status,
    br.created_at
  FROM base_results br
  WHERE
    NOT v_low_specificity_query
    OR scope_contact_id IS NOT NULL
    OR scope_phone IS NOT NULL
    OR br.project_id = (SELECT tp.project_id FROM top_project tp)
  ORDER BY br.distance
  LIMIT result_limit;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.xref_search_journal_claims(
  extensions.vector(1536), uuid, text, integer, double precision, text
) TO service_role;
COMMENT ON FUNCTION public.xref_search_journal_claims(
  extensions.vector(1536), uuid, text, integer, double precision, text
) IS
'Semantic search over journal claims with optional scope filters and a low-specificity material/color guard via query_hint_text.';
