-- M2-C: Vector embeddings on project_facts for semantic retrieval
-- Follows journal_claims embedding pattern (20260215210100).
-- Dimension: 1536 (text-embedding-3-small).
-- HNSW index deferred until >1000 embedded rows (see rollout gate below).
-- search_text is GENERATED ALWAYS so it auto-updates when fact_payload changes.

-- 1) Add search_text (shared across FTS/trigram/vector) + embedding columns
ALTER TABLE public.project_facts
  ADD COLUMN IF NOT EXISTS search_text text GENERATED ALWAYS AS (
    fact_kind || ' ' ||
    coalesce(fact_payload->>'feature', '') || ' ' ||
    coalesce(fact_payload->>'value', '') || ' ' ||
    coalesce(fact_payload->>'notes', '')
  ) STORED,
  ADD COLUMN IF NOT EXISTS embedding extensions.vector(1536),
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS embedding_version text;

COMMENT ON COLUMN public.project_facts.search_text IS
  'M2-0: Auto-generated search text for hybrid retrieval (FTS, trigram, vector). '
  'Combines fact_kind + extracted fact_payload fields (feature, value, notes). '
  'Auto-populated on insert/update; no pipeline dependency.';
COMMENT ON COLUMN public.project_facts.embedding IS
  'Vector embedding of search_text. Dimension=1536 (text-embedding-3-small).';
COMMENT ON COLUMN public.project_facts.embedding_model IS
  'Model used to generate embedding (e.g., text-embedding-3-small).';
COMMENT ON COLUMN public.project_facts.embedding_version IS
  'Version tag for embedding generation (e.g., v1). Bump on re-embed.';

-- 2) Partial B-tree index (interim, until HNSW rollout)
--    Covers the common query path: filter by project, then scan embeddings.
CREATE INDEX IF NOT EXISTS idx_project_facts_embedded
  ON public.project_facts (project_id)
  WHERE embedding IS NOT NULL;

COMMENT ON INDEX public.idx_project_facts_embedded IS
  'Partial index for vector search over project_facts. '
  'Covers rows with non-null embeddings. '
  'HNSW vector index deferred until >1000 embedded rows.';

-- 3) HNSW rollout gate (DO NOT APPLY until conditions met)
--
-- ROLLOUT GATE: Do NOT create HNSW until:
--   1) Embeddings are backfilled (>1000 rows with non-null embedding)
--   2) Sequential scan latency on cosine distance queries exceeds 100ms at p95
--
-- Current volume: ~65 project_facts rows, 0 embeddings. Sequential scan is sufficient.
-- HNSW becomes beneficial around 10k+ embedded rows.
--
-- When ready, run this index creation:
--
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_project_facts_embedding_hnsw
--   ON public.project_facts
--   USING hnsw (embedding extensions.vector_cosine_ops)
--   WITH (m = 16, ef_construction = 64)
--   WHERE embedding IS NOT NULL;

-- 4) Context-assembly query pattern documentation
--
-- search_text is auto-generated. The embed-facts edge function populates embedding.
-- context-assembly retrieves relevant facts with this query pattern:
--
-- SELECT pf.*, 1 - (pf.embedding <=> $span_embedding) AS cosine_sim
-- FROM project_facts pf
-- WHERE pf.embedding IS NOT NULL
--   AND pf.as_of_at  <= $t_call
--   AND pf.observed_at <= $t_call
-- ORDER BY pf.embedding <=> $span_embedding
-- LIMIT 20;
--
-- For project-scoped retrieval (most common):
--
-- SELECT pf.*, 1 - (pf.embedding <=> $span_embedding) AS cosine_sim
-- FROM project_facts pf
-- WHERE pf.project_id = $project_id
--   AND pf.embedding IS NOT NULL
--   AND pf.as_of_at  <= $t_call
--   AND pf.observed_at <= $t_call
-- ORDER BY pf.embedding <=> $span_embedding
-- LIMIT 20;
