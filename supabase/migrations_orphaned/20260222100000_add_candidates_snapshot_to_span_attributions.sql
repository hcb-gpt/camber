-- Add candidates_snapshot to span_attributions
-- Persists the full candidate ranking at attribution time for explainability
-- Gap 2 fix: currently only review_queue items get candidates in context_payload
ALTER TABLE public.span_attributions
ADD COLUMN IF NOT EXISTS candidates_snapshot jsonb;

COMMENT ON COLUMN public.span_attributions.candidates_snapshot IS
  'Snapshot of all candidate projects considered at attribution time. Schema: [{project_id, project_name, affinity_weight, source_strength, evidence_sources}]';
