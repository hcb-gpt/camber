CREATE TABLE public.attribution_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  span_id uuid NOT NULL REFERENCES conversation_spans(id) ON DELETE CASCADE,
  attribution_id uuid NOT NULL,
  -- Full snapshot of attribution state
  project_id uuid, confidence numeric, decision text,
  applied_project_id uuid, gatekeeper_reason text,
  gatekeeper_details jsonb, prompt_version text, model_id text,
  pipeline_versions jsonb, attribution_source text,
  evidence_tier integer, reasoning text, anchors jsonb,
  attribution_lock text, attributed_by text, attributed_at timestamptz,
  needs_review boolean, candidates_snapshot jsonb,
  -- History metadata
  action text NOT NULL CHECK (action IN ('create','update','backfill','review_override','reseed')),
  actor text NOT NULL DEFAULT 'pipeline',
  change_summary text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_attr_history_span ON attribution_history(span_id, created_at DESC);
CREATE INDEX idx_attr_history_model_prompt ON attribution_history(model_id, prompt_version);;
