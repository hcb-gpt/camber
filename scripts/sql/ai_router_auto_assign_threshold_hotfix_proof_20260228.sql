-- Proof pack: ai-router auto-assign threshold hotfix (0.75 -> 0.60)
-- Usage:
--   /usr/local/opt/libpq/bin/psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/ai_router_auto_assign_threshold_hotfix_proof_20260228.sql

\echo 'Q1) Config row for ai_router_auto_assign_threshold'
select
  config_key,
  config_value,
  updated_at,
  updated_by,
  description
from public.inference_config
where config_key = 'ai_router_auto_assign_threshold';

\echo 'Q2) Parsed threshold value + in-bounds check'
select
  (config_value)::numeric as threshold_value,
  ((config_value)::numeric >= 0 and (config_value)::numeric <= 1) as in_bounds,
  case when (config_value)::numeric = 0.60 then true else false end as is_hotfix_target
from public.inference_config
where config_key = 'ai_router_auto_assign_threshold';

\echo 'Q3) Last 7d review rows in [0.60,0.75) band (potential impact window)'
select
  count(*)::int as review_rows_060_to_075,
  min(attributed_at) as min_attributed_at,
  max(attributed_at) as max_attributed_at
from public.span_attributions
where attributed_at >= now() - interval '7 days'
  and decision = 'review'
  and confidence >= 0.60
  and confidence < 0.75;
