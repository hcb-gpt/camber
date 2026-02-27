
-- Helper function: edge functions call this to get their model config
-- Usage: SELECT * FROM get_model_config('ai-router');
CREATE OR REPLACE FUNCTION public.get_model_config(p_function_name text)
RETURNS TABLE (
  provider text,
  model_id text,
  fallback_provider text,
  fallback_model_id text,
  max_tokens int,
  temperature numeric
) LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT provider, model_id, fallback_provider, fallback_model_id, max_tokens, temperature
  FROM public.pipeline_model_config
  WHERE function_name = p_function_name;
$$;

-- Auto-generated README view — queryable documentation
-- This IS the README. Query it, don't maintain a separate doc.
CREATE OR REPLACE VIEW public.v_pipeline_model_readme AS
SELECT 
  function_name,
  provider || '/' || model_id AS current_model,
  COALESCE(fallback_provider || '/' || fallback_model_id, 'none') AS fallback_model,
  task_type,
  rationale,
  benchmarks_consulted AS sources,
  '$' || estimated_cost_per_1k_calls::text || ' per 1k calls' AS estimated_cost,
  updated_by AS last_updated_by,
  updated_at AS last_updated
FROM public.pipeline_model_config
ORDER BY task_type, function_name;

COMMENT ON VIEW public.v_pipeline_model_readme IS 'Self-documenting README for pipeline LLM models. Query this instead of maintaining separate docs. Shows current model, rationale, sources, cost estimate.';
COMMENT ON FUNCTION public.get_model_config IS 'Edge functions call this on cold start to get their model config. Returns provider, model_id, fallback, max_tokens, temperature.';
;
