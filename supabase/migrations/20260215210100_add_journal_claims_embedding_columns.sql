-- Add embedding columns to journal_claims for semantic crossref
-- Using 1536 dimensions (OpenAI text-embedding-3-small default)
-- Applied by DATA-2 session, 2026-02-15

ALTER TABLE public.journal_claims
  ADD COLUMN IF NOT EXISTS search_text text,
  ADD COLUMN IF NOT EXISTS embedding extensions.vector(1536),
  ADD COLUMN IF NOT EXISTS embedding_model text,
  ADD COLUMN IF NOT EXISTS embedding_version text;
COMMENT ON COLUMN public.journal_claims.search_text IS 'Concatenated searchable text derived from claim_text + context. Used as embedding input.';
COMMENT ON COLUMN public.journal_claims.embedding IS 'Vector embedding of search_text. Dimension=1536 (text-embedding-3-small).';
COMMENT ON COLUMN public.journal_claims.embedding_model IS 'Model used to generate embedding (e.g., text-embedding-3-small).';
COMMENT ON COLUMN public.journal_claims.embedding_version IS 'Version tag for embedding generation (e.g., v1). Bump on re-embed.';
