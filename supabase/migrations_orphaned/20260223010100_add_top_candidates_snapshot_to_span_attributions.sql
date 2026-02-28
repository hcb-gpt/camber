-- Persist decision-time candidate snapshots for explainability on every attribution row.
ALTER TABLE public.span_attributions
  ADD COLUMN IF NOT EXISTS top_candidates jsonb DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS runner_up_confidence numeric,
  ADD COLUMN IF NOT EXISTS candidate_count smallint;

COMMENT ON COLUMN public.span_attributions.top_candidates IS
  'Top candidate projects at decision time. Array of {project_id, confidence, anchor_type}.';
COMMENT ON COLUMN public.span_attributions.runner_up_confidence IS
  'Confidence score of the second-best candidate. Null when fewer than 2 candidates.';
COMMENT ON COLUMN public.span_attributions.candidate_count IS
  'Total number of deduplicated candidates considered at attribution decision time.';
