CREATE INDEX IF NOT EXISTS idx_sa_gatekeeper_conf ON public.span_attributions(gatekeeper_reason, confidence) WHERE gatekeeper_reason IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sa_pipeline_gin ON public.span_attributions USING gin(pipeline_versions jsonb_path_ops) WHERE pipeline_versions IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_avf_verdict_span ON public.attribution_validation_feedback(verdict, span_id);;
