-- Migration: Create labeling_results table for world-model labeling pipeline
-- Owner: DATA (world-model-prep)
-- Consumer: pass0_deterministic.ts through pass4_review_queue.ts
-- References: /tmp/wm-prep-pipeline-design.md Section D2

CREATE TABLE IF NOT EXISTS public.labeling_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  span_id UUID NOT NULL REFERENCES public.conversation_spans(id),
  interaction_id TEXT NOT NULL,

  -- Label
  project_id UUID REFERENCES public.projects(id),
  label_decision TEXT NOT NULL DEFAULT 'unlabeled'
    CHECK (label_decision IN ('assign','none','review','unlabeled')),
  confidence NUMERIC(4,3),

  -- Provenance
  label_source TEXT NOT NULL
    CHECK (label_source IN (
      'pass0_phone_match',
      'pass0_homeowner_regex',
      'pass0_staff_exclusion',
      'pass0_single_vendor',
      'pass1_graph_propagation',
      'pass1_temporal_cluster',
      'pass1_sub_transitivity',
      'pass2_haiku_triage',
      'pass3_opus_deep_label',
      'pass4_human_review',
      'gt_correction'
    )),
  pass_number INTEGER NOT NULL CHECK (pass_number BETWEEN 0 AND 4),
  batch_run_id TEXT NOT NULL,

  -- LLM metadata (Pass 2-3 only)
  model_id TEXT,
  tokens_used INTEGER,
  inference_ms INTEGER,
  raw_response JSONB,

  -- Fact extraction (Pass 3 only)
  extracted_facts JSONB,

  -- Audit
  labeled_at TIMESTAMPTZ DEFAULT NOW(),
  superseded_by UUID REFERENCES public.labeling_results(id),

  UNIQUE(span_id, batch_run_id)
);

CREATE INDEX IF NOT EXISTS idx_labeling_results_span ON public.labeling_results(span_id);
CREATE INDEX IF NOT EXISTS idx_labeling_results_batch ON public.labeling_results(batch_run_id);
CREATE INDEX IF NOT EXISTS idx_labeling_results_pass ON public.labeling_results(pass_number);
CREATE INDEX IF NOT EXISTS idx_labeling_results_source ON public.labeling_results(label_source);
CREATE INDEX IF NOT EXISTS idx_labeling_results_decision ON public.labeling_results(label_decision)
  WHERE label_decision IN ('review','unlabeled');

COMMENT ON TABLE public.labeling_results IS
  'World-model labeling pipeline output. One label per span per batch run. '
  'Separate from span_attributions (production SSOT) per Stopline 1.';
COMMENT ON COLUMN public.labeling_results.label_source IS
  'Which pass/rule produced this label. Provenance for audit and evaluation.';
COMMENT ON COLUMN public.labeling_results.batch_run_id IS
  'Groups all labels from one pipeline run. Format: wm-label-YYYYMMDD-shortid';
COMMENT ON COLUMN public.labeling_results.superseded_by IS
  'If a later pass re-labeled this span, points to the replacement row.';
