-- M2-B: Trigram index on project_facts.fact_text_compact

CREATE EXTENSION IF NOT EXISTS pg_trgm;

ALTER TABLE public.project_facts
  ADD COLUMN IF NOT EXISTS fact_text_compact text GENERATED ALWAYS AS (
    fact_kind || ' ' || COALESCE(fact_payload::text, '')
  ) STORED;

CREATE INDEX IF NOT EXISTS idx_project_facts_fact_text_compact_trgm_gist
  ON public.project_facts USING GIST (fact_text_compact gist_trgm_ops);

COMMENT ON COLUMN public.project_facts.fact_text_compact IS
  'Compact generated text for project_facts retrieval: fact_kind plus fact_payload text.';

COMMENT ON INDEX public.idx_project_facts_fact_text_compact_trgm_gist IS
  'M2-B: GiST trigram index over fact_text_compact.';
