-- Epic C (Epistemic Hygiene v0)
-- Goal: prevent unconfirmed journal claims from contaminating retrieval/consolidation.
--
-- Changes:
-- 1) Add claim confirmation state fields to journal_claims.
-- 2) Backfill confirmation state from deterministic assign lane.
-- 3) Enforce xref_search_journal_claims to return confirmed claims only.

BEGIN;
ALTER TABLE public.journal_claims
  ADD COLUMN IF NOT EXISTS claim_confirmation_state text,
  ADD COLUMN IF NOT EXISTS confirmed_at timestamptz,
  ADD COLUMN IF NOT EXISTS confirmed_by text;
UPDATE public.journal_claims
SET
  claim_confirmation_state = CASE
    WHEN claim_project_id IS NOT NULL AND attribution_decision = 'assign' THEN 'confirmed'
    ELSE 'unconfirmed'
  END,
  confirmed_at = CASE
    WHEN claim_project_id IS NOT NULL AND attribution_decision = 'assign' THEN COALESCE(confirmed_at, created_at, NOW())
    ELSE NULL
  END,
  confirmed_by = CASE
    WHEN claim_project_id IS NOT NULL AND attribution_decision = 'assign' THEN COALESCE(confirmed_by, 'backfill_auto_assign')
    ELSE NULL
  END
WHERE claim_confirmation_state IS NULL
   OR claim_confirmation_state NOT IN ('confirmed', 'unconfirmed');
UPDATE public.journal_claims
SET claim_confirmation_state = 'unconfirmed'
WHERE claim_confirmation_state IS NULL;
ALTER TABLE public.journal_claims
  ALTER COLUMN claim_confirmation_state SET DEFAULT 'unconfirmed',
  ALTER COLUMN claim_confirmation_state SET NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_journal_claims_confirmation_state'
      AND conrelid = 'public.journal_claims'::regclass
  ) THEN
    ALTER TABLE public.journal_claims
      ADD CONSTRAINT chk_journal_claims_confirmation_state
      CHECK (claim_confirmation_state IN ('confirmed', 'unconfirmed'));
  END IF;
END
$$;
CREATE INDEX IF NOT EXISTS idx_journal_claims_active_confirmed_project_created
  ON public.journal_claims (project_id, created_at DESC)
  WHERE active = true AND claim_confirmation_state = 'confirmed';
CREATE INDEX IF NOT EXISTS idx_journal_claims_active_confirmed_claim_project
  ON public.journal_claims (claim_project_id)
  WHERE active = true
    AND claim_confirmation_state = 'confirmed'
    AND claim_project_id IS NOT NULL;
COMMENT ON COLUMN public.journal_claims.claim_confirmation_state IS
  'Contamination-control state for reusable retrieval. confirmed|unconfirmed.';
COMMENT ON COLUMN public.journal_claims.confirmed_at IS
  'Timestamp claim transitioned to confirmed state.';
COMMENT ON COLUMN public.journal_claims.confirmed_by IS
  'Actor or subsystem that confirmed claim (e.g., review_resolve, journal_extract_auto_assign).';
CREATE OR REPLACE FUNCTION public.xref_search_journal_claims(
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
      AND jc.claim_confirmation_state = 'confirmed'
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
'Semantic search over confirmed journal claims with optional scope filters and a low-specificity material/color guard via query_hint_text.';
COMMIT;
