
-- Centralized model configuration for all LLM-calling edge functions
-- Eliminates hardcoded model IDs. Functions read this table on cold start.
-- Chad directive: NO HARDCODING IN PIPELINE.

CREATE TABLE IF NOT EXISTS public.pipeline_model_config (
  function_name text PRIMARY KEY,
  provider text NOT NULL CHECK (provider IN ('anthropic', 'openai', 'deepseek', 'google')),
  model_id text NOT NULL,
  fallback_provider text CHECK (fallback_provider IN ('anthropic', 'openai', 'deepseek', 'google', NULL)),
  fallback_model_id text,
  max_tokens int DEFAULT 1024,
  temperature numeric DEFAULT 0.0,
  task_type text NOT NULL, -- classification, extraction, summarization, reasoning, conversational
  rationale text NOT NULL, -- WHY this model for this task
  benchmarks_consulted text, -- sources used to make the decision
  estimated_cost_per_1k_calls numeric, -- rough cost estimate
  last_benchmarked_at timestamptz DEFAULT now(),
  updated_by text DEFAULT 'strat-vp',
  updated_at timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.pipeline_model_config ENABLE ROW LEVEL SECURITY;

-- Read access for edge functions (anon + service role)
CREATE POLICY "pipeline_model_config_read" ON public.pipeline_model_config
  FOR SELECT USING (true);

-- Write access for service role only
CREATE POLICY "pipeline_model_config_write" ON public.pipeline_model_config
  FOR ALL USING (auth.role() = 'service_role');

COMMENT ON TABLE public.pipeline_model_config IS 'Centralized LLM model config. Edge functions read on cold start. NO hardcoded model IDs in function source.';
COMMENT ON COLUMN public.pipeline_model_config.rationale IS 'Human-readable explanation of why this model was chosen for this task. Required.';
COMMENT ON COLUMN public.pipeline_model_config.fallback_provider IS 'Failover provider if primary is down or rate-limited';
;
