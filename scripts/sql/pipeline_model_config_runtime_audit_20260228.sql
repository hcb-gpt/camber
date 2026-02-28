-- Runtime audit for pipeline_model_config rollout:
-- - configured functions and values
-- - recent DB footprints indicating active model usage
-- - helper adoption in edge code is reported separately in docs

select
  function_name,
  provider,
  model_id,
  fallback_provider,
  fallback_model_id,
  max_tokens,
  temperature,
  updated_at
from public.pipeline_model_config
order by function_name;

select
  coalesce(attributed_by, '') as attributed_by,
  coalesce(prompt_version, '') as prompt_version,
  coalesce(model_id, '') as model_id,
  count(*)::int as rows_24h,
  max(coalesce(applied_at_utc, attributed_at)) as last_at
from public.span_attributions
where coalesce(applied_at_utc, attributed_at) >= now() - interval '24 hours'
group by 1, 2, 3
order by rows_24h desc
limit 25;

select
  coalesce(extraction_model_id, '') as extraction_model_id,
  count(*)::int as rows_24h,
  max(created_at) as last_at
from public.journal_claims
where created_at >= now() - interval '24 hours'
group by 1
order by rows_24h desc
limit 25;

-- Focused sanity check for functions already known to call get_model_config in code.
select
  pmc.function_name,
  pmc.model_id as configured_model_id,
  pmc.temperature as configured_temperature,
  pmc.updated_at as config_updated_at
from public.pipeline_model_config pmc
where pmc.function_name in ('ai-router', 'journal-extract', 'segment-llm')
order by pmc.function_name;

