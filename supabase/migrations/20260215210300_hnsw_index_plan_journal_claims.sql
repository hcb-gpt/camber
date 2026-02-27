-- HNSW index plan for journal_claims embeddings
-- Applied by DATA-2 session, 2026-02-15
--
-- ROLLOUT GATE: Do NOT create HNSW until:
--   1) Embeddings are backfilled (>1000 rows with non-null embedding)
--   2) Query latency on xref_search_journal_claims exceeds 100ms at p95
--
-- Current volume: ~5k claims, 0 embeddings. Sequential scan is sufficient.
-- HNSW becomes beneficial around 10k+ embedded rows.
--
-- When ready, run this index creation:
--
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_journal_claims_embedding_hnsw
--   ON public.journal_claims
--   USING hnsw (embedding extensions.vector_cosine_ops)
--   WITH (m = 16, ef_construction = 64)
--   WHERE embedding IS NOT NULL AND active = true;

-- For now: partial B-tree index on active claims with embeddings
CREATE INDEX IF NOT EXISTS idx_journal_claims_active_embedded
  ON public.journal_claims (project_id)
  WHERE embedding IS NOT NULL AND active = true;
COMMENT ON INDEX public.idx_journal_claims_active_embedded IS
  'Partial index for xref_search_journal_claims RPC. '
  'Covers active claims with embeddings. '
  'HNSW vector index deferred until >1000 embedded rows.';
