-- M2-A: Full-text search index on project_facts.fact_text_compact

CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER TABLE public.project_facts
  ADD COLUMN IF NOT EXISTS fact_text_compact text GENERATED ALWAYS AS (
    fact_kind || ' ' || COALESCE(fact_payload::text, '')
  ) STORED;

CREATE INDEX IF NOT EXISTS idx_project_facts_fact_text_compact_fts
  ON public.project_facts USING GIN (to_tsvector('english', fact_text_compact));

COMMENT ON COLUMN public.project_facts.fact_text_compact IS
  'Compact generated text for project_facts retrieval: fact_kind plus fact_payload text.';

COMMENT ON INDEX public.idx_project_facts_fact_text_compact_fts IS
  'M2-A: GIN full-text search index over fact_text_compact.';
