-- Migration: Add attribution_lock to labeling_results, tags to project_facts
-- Owner: STRAT-4 (world-model-prep pipeline execution)
-- Required by: CHAD directive execute_labeling_pipeline_live

-- attribution_lock identifies which pipeline pass owns each label
ALTER TABLE public.labeling_results
  ADD COLUMN IF NOT EXISTS attribution_lock TEXT;

COMMENT ON COLUMN public.labeling_results.attribution_lock IS
  'Identifies which pipeline pass owns this label (e.g., pass0_deterministic, pass1_graph). Set during pipeline execution.';

-- tags array on project_facts for metadata tagging (PIPELINE_EXTRACTED, etc.)
ALTER TABLE public.project_facts
  ADD COLUMN IF NOT EXISTS tags JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.project_facts.tags IS
  'Metadata tags array. PIPELINE_EXTRACTED marks machine-extracted facts from labeling pipeline.';

-- Index for querying pipeline-extracted facts
CREATE INDEX IF NOT EXISTS idx_project_facts_tags ON public.project_facts USING gin(tags);
