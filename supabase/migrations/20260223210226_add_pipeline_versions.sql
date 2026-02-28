ALTER TABLE public.span_attributions
  ADD COLUMN IF NOT EXISTS pipeline_versions jsonb;;
