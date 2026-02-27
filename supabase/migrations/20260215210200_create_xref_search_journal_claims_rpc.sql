-- Semantic crossref search over journal_claims embeddings
-- Accepts a pre-computed query embedding and returns nearest claims
-- with project attribution and distance score.
-- Compatible with context-assembly Source 5 usage pattern.
-- Applied by DATA-2 session, 2026-02-15

CREATE OR REPLACE FUNCTION public.xref_search_journal_claims(
  query_embedding extensions.vector(1536),
  scope_contact_id uuid DEFAULT NULL,
  scope_phone text DEFAULT NULL,
  result_limit integer DEFAULT 10,
  max_distance double precision DEFAULT 0.5
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
BEGIN
  RETURN QUERY
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
        AND (cr.from_number = scope_phone OR cr.to_number = scope_phone)
    ))
    AND (jc.embedding <=> query_embedding) <= max_distance
  ORDER BY jc.embedding <=> query_embedding
  LIMIT result_limit;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.xref_search_journal_claims(
  extensions.vector(1536), uuid, text, integer, double precision
) TO service_role;
COMMENT ON FUNCTION public.xref_search_journal_claims IS
  'Semantic vector search over journal_claims. Returns nearest claims by cosine distance. '
  'Accepts pre-computed query embedding (1536d). Optional scope by contact_id or phone. '
  'Used by context-assembly for cross-reference attribution (Source 5).';
