-- Migration: add_journal_claim_conflict_candidate_functions
-- Purpose: Add deterministic, non-destructive conflict candidate discovery over
-- journal_claims embeddings and proposal mapping into belief_conflicts linkage.
-- Note: This migration defines helper functions only; it does not write rows to
-- belief_conflicts or conflict_claims by itself.

BEGIN;
CREATE OR REPLACE FUNCTION public.detect_journal_claim_conflict_candidates(
  p_project_id uuid DEFAULT NULL,
  p_since timestamptz DEFAULT (now() - interval '14 days'),
  p_max_distance double precision DEFAULT 0.35,
  p_min_contradiction_score double precision DEFAULT 0.70,
  p_result_limit integer DEFAULT 200
)
RETURNS TABLE(
  project_id uuid,
  claim_type text,
  claim_a_id uuid,
  claim_b_id uuid,
  claim_a_text text,
  claim_b_text text,
  speaker_a_contact_id uuid,
  speaker_b_contact_id uuid,
  semantic_distance double precision,
  contradiction_score double precision,
  inferred_conflict_type public.conflict_type_enum,
  summary text
)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
WITH candidate_pairs AS (
  SELECT
    a.project_id,
    a.claim_type,
    a.id AS claim_a_id,
    b.id AS claim_b_id,
    a.claim_text AS claim_a_text,
    b.claim_text AS claim_b_text,
    a.speaker_contact_id AS speaker_a_contact_id,
    b.speaker_contact_id AS speaker_b_contact_id,
    (a.embedding <=> b.embedding)::double precision AS semantic_distance,
    lower(a.claim_text) AS claim_a_text_l,
    lower(b.claim_text) AS claim_b_text_l
  FROM public.journal_claims a
  JOIN public.journal_claims b
    ON a.project_id = b.project_id
   AND a.claim_type = b.claim_type
   AND a.id < b.id
  WHERE a.active = true
    AND b.active = true
    AND a.embedding IS NOT NULL
    AND b.embedding IS NOT NULL
    AND COALESCE(a.claim_confirmation_state, 'confirmed') = 'confirmed'
    AND COALESCE(b.claim_confirmation_state, 'confirmed') = 'confirmed'
    AND a.project_id IS NOT NULL
    AND (p_project_id IS NULL OR a.project_id = p_project_id)
    AND a.created_at >= p_since
    AND b.created_at >= p_since
    AND COALESCE(a.speaker_contact_id::text, '') <> COALESCE(b.speaker_contact_id::text, '')
    AND (a.embedding <=> b.embedding) <= p_max_distance
),
signals AS (
  SELECT
    cp.*,
    (cp.claim_a_text_l ~ '(^|[^a-z])(no|not|never|cannot|can''t|won''t|didn''t|isn''t|aren''t|without|none)([^a-z]|$)') AS a_has_negation,
    (cp.claim_b_text_l ~ '(^|[^a-z])(no|not|never|cannot|can''t|won''t|didn''t|isn''t|aren''t|without|none)([^a-z]|$)') AS b_has_negation,
    (cp.claim_a_text_l ~ '(^|[^a-z])(done|complete|completed|approved|shipped|on[[:space:]]+track|started)([^a-z]|$)') AS a_has_positive_state,
    (cp.claim_b_text_l ~ '(^|[^a-z])(done|complete|completed|approved|shipped|on[[:space:]]+track|started)([^a-z]|$)') AS b_has_positive_state,
    (cp.claim_a_text_l ~ '(^|[^a-z])(blocked|delay|delayed|late|stalled|stuck|pending|behind)([^a-z]|$)') AS a_has_negative_state,
    (cp.claim_b_text_l ~ '(^|[^a-z])(blocked|delay|delayed|late|stalled|stuck|pending|behind)([^a-z]|$)') AS b_has_negative_state,
    substring(cp.claim_a_text_l from '([0-9]{1,2}/[0-9]{1,2}(/[0-9]{2,4})?|jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|jun(e)?|jul(y)?|aug(ust)?|sep(t|tember)?|oct(ober)?|nov(ember)?|dec(ember)?)') AS a_date_token,
    substring(cp.claim_b_text_l from '([0-9]{1,2}/[0-9]{1,2}(/[0-9]{2,4})?|jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|jun(e)?|jul(y)?|aug(ust)?|sep(t|tember)?|oct(ober)?|nov(ember)?|dec(ember)?)') AS b_date_token,
    substring(cp.claim_a_text_l from '([0-9]{1,4})') AS a_number_token,
    substring(cp.claim_b_text_l from '([0-9]{1,4})') AS b_number_token
  FROM candidate_pairs cp
),
scored AS (
  SELECT
    s.project_id,
    s.claim_type,
    s.claim_a_id,
    s.claim_b_id,
    s.claim_a_text,
    s.claim_b_text,
    s.speaker_a_contact_id,
    s.speaker_b_contact_id,
    s.semantic_distance,
    (
      s.a_has_negation <> s.b_has_negation
    ) AS negation_mismatch,
    (
      (s.a_has_positive_state AND s.b_has_negative_state)
      OR (s.b_has_positive_state AND s.a_has_negative_state)
    ) AS polarity_flip,
    (
      s.a_date_token IS NOT NULL
      AND s.b_date_token IS NOT NULL
      AND s.a_date_token <> s.b_date_token
    ) AS date_mismatch_hint,
    (
      s.a_number_token IS NOT NULL
      AND s.b_number_token IS NOT NULL
      AND s.a_number_token <> s.b_number_token
    ) AS number_mismatch_hint
  FROM signals s
)
SELECT
  sc.project_id,
  sc.claim_type,
  sc.claim_a_id,
  sc.claim_b_id,
  sc.claim_a_text,
  sc.claim_b_text,
  sc.speaker_a_contact_id,
  sc.speaker_b_contact_id,
  sc.semantic_distance,
  LEAST(
    0.99::double precision,
    GREATEST(
      0.0::double precision,
      ((1.0 - LEAST(sc.semantic_distance, 1.0)) * 0.55)
      + (CASE WHEN sc.polarity_flip THEN 0.20 ELSE 0.00 END)
      + (CASE WHEN sc.negation_mismatch THEN 0.15 ELSE 0.00 END)
      + (CASE WHEN sc.date_mismatch_hint THEN 0.15 ELSE 0.00 END)
      + (CASE WHEN sc.number_mismatch_hint THEN 0.10 ELSE 0.00 END)
    )
  ) AS contradiction_score,
  (
    CASE
      WHEN sc.date_mismatch_hint THEN 'temporal'
      WHEN sc.polarity_flip THEN 'commitment'
      ELSE 'factual'
    END
  )::public.conflict_type_enum AS inferred_conflict_type,
  format(
    '%s conflict candidate (%s): "%s" <> "%s"',
    (
      CASE
        WHEN sc.date_mismatch_hint THEN 'temporal'
        WHEN sc.polarity_flip THEN 'commitment'
        ELSE 'factual'
      END
    ),
    sc.claim_type,
    left(sc.claim_a_text, 120),
    left(sc.claim_b_text, 120)
  ) AS summary
FROM scored sc
WHERE LEAST(
    0.99::double precision,
    GREATEST(
      0.0::double precision,
      ((1.0 - LEAST(sc.semantic_distance, 1.0)) * 0.55)
      + (CASE WHEN sc.polarity_flip THEN 0.20 ELSE 0.00 END)
      + (CASE WHEN sc.negation_mismatch THEN 0.15 ELSE 0.00 END)
      + (CASE WHEN sc.date_mismatch_hint THEN 0.15 ELSE 0.00 END)
      + (CASE WHEN sc.number_mismatch_hint THEN 0.10 ELSE 0.00 END)
    )
  ) >= p_min_contradiction_score
ORDER BY contradiction_score DESC, semantic_distance ASC, claim_a_id, claim_b_id
LIMIT p_result_limit;
$function$;
COMMENT ON FUNCTION public.detect_journal_claim_conflict_candidates(
  uuid, timestamptz, double precision, double precision, integer
) IS
  'Design-time candidate detector for contradictory journal_claim pairs. '
  'Uses embedding distance plus lexical contradiction signals and returns scored candidates only.';
GRANT EXECUTE ON FUNCTION public.detect_journal_claim_conflict_candidates(
  uuid, timestamptz, double precision, double precision, integer
) TO service_role;
CREATE OR REPLACE FUNCTION public.propose_belief_conflicts_from_journal_claims(
  p_project_id uuid DEFAULT NULL,
  p_since timestamptz DEFAULT (now() - interval '14 days'),
  p_max_distance double precision DEFAULT 0.35,
  p_min_contradiction_score double precision DEFAULT 0.70,
  p_result_limit integer DEFAULT 200
)
RETURNS TABLE(
  project_id uuid,
  claim_type text,
  inferred_conflict_type public.conflict_type_enum,
  claim_a_id uuid,
  claim_b_id uuid,
  belief_claim_a_id uuid,
  belief_claim_b_id uuid,
  semantic_distance double precision,
  contradiction_score double precision,
  summary text,
  existing_conflict_id uuid,
  ready_to_insert boolean
)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
WITH candidates AS (
  SELECT *
  FROM public.detect_journal_claim_conflict_candidates(
    p_project_id,
    p_since,
    p_max_distance,
    p_min_contradiction_score,
    p_result_limit
  )
),
mapped AS (
  SELECT
    c.project_id,
    c.claim_type,
    c.inferred_conflict_type,
    c.claim_a_id,
    c.claim_b_id,
    CASE
      WHEN ba.id::text <= bb.id::text THEN ba.id
      ELSE bb.id
    END AS belief_claim_a_id,
    CASE
      WHEN ba.id::text <= bb.id::text THEN bb.id
      ELSE ba.id
    END AS belief_claim_b_id,
    c.semantic_distance,
    c.contradiction_score,
    c.summary
  FROM candidates c
  JOIN public.belief_claims ba
    ON ba.journal_claim_id = c.claim_a_id
  JOIN public.belief_claims bb
    ON bb.journal_claim_id = c.claim_b_id
),
with_existing AS (
  SELECT
    m.*,
    ec.conflict_id AS existing_conflict_id
  FROM mapped m
  LEFT JOIN LATERAL (
    SELECT cc1.conflict_id
    FROM public.conflict_claims cc1
    JOIN public.conflict_claims cc2
      ON cc2.conflict_id = cc1.conflict_id
    WHERE cc1.claim_id = m.belief_claim_a_id
      AND cc2.claim_id = m.belief_claim_b_id
    LIMIT 1
  ) ec ON true
)
SELECT
  project_id,
  claim_type,
  inferred_conflict_type,
  claim_a_id,
  claim_b_id,
  belief_claim_a_id,
  belief_claim_b_id,
  semantic_distance,
  contradiction_score,
  summary,
  existing_conflict_id,
  (existing_conflict_id IS NULL) AS ready_to_insert
FROM with_existing
ORDER BY contradiction_score DESC, semantic_distance ASC, claim_a_id, claim_b_id
LIMIT p_result_limit;
$function$;
COMMENT ON FUNCTION public.propose_belief_conflicts_from_journal_claims(
  uuid, timestamptz, double precision, double precision, integer
) IS
  'Proposal-only mapping from journal claim conflict candidates to belief_conflicts-ready pairs. '
  'No writes are performed; output includes existing_conflict_id and ready_to_insert.';
GRANT EXECUTE ON FUNCTION public.propose_belief_conflicts_from_journal_claims(
  uuid, timestamptz, double precision, double precision, integer
) TO service_role;
COMMIT;
