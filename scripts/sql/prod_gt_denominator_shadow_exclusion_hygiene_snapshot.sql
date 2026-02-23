-- prod_gt_denominator_shadow_exclusion_hygiene_snapshot.sql
--
-- Proof snapshot for GT denominator hygiene policy:
-- - Exclude only PIPELINE_NULL rows that are known non-prod:
--   1) shadow fixtures (interactions.is_shadow=true or call_id prefix cll_SHADOW_)
--   2) blocked contact cohort (contact_name regex: sittler|madison|athens|bishop)

\pset format aligned
\pset tuples_only off

\echo 'Q1: Exclusion set (interaction IDs + reason)'
select
  call_id,
  exclusion_reason,
  contact_name,
  event_at_utc
from public.v_ground_truth_evaluable_non_prod_exclusions
order by event_at_utc desc nulls last, call_id;

\echo ''
\echo 'Q2: Exclusion bucket counts'
select
  exclusion_reason,
  count(*) as n
from public.v_ground_truth_evaluable_non_prod_exclusions
group by exclusion_reason
order by n desc, exclusion_reason;

\echo ''
\echo 'Q3: Before vs after denominator + agreement metrics'
with before_metrics as (
  select
    count(*)::int as denominator,
    round(100.0 * sum(case when agreement = 'MATCH' then 1 else 0 end) / nullif(count(*), 0), 2) as match_rate_pct,
    round(100.0 * sum(case when agreement = 'PIPELINE_NULL' then 1 else 0 end) / nullif(count(*), 0), 2) as pipeline_null_rate_pct
  from public.v_ground_truth_evaluable
),
after_metrics as (
  select
    count(*)::int as denominator,
    round(100.0 * sum(case when agreement = 'MATCH' then 1 else 0 end) / nullif(count(*), 0), 2) as match_rate_pct,
    round(100.0 * sum(case when agreement = 'PIPELINE_NULL' then 1 else 0 end) / nullif(count(*), 0), 2) as pipeline_null_rate_pct
  from public.v_ground_truth_evaluable_prod
)
select
  'before' as scope,
  b.denominator,
  b.match_rate_pct,
  b.pipeline_null_rate_pct
from before_metrics b
union all
select
  'after_policy_exclusion' as scope,
  a.denominator,
  a.match_rate_pct,
  a.pipeline_null_rate_pct
from after_metrics a;

\echo ''
\echo 'Q4: Policy criteria (auto-exclusion rules)'
select
  'PIPELINE_NULL + (is_shadow=true OR call_id like cll_SHADOW_% OR blocked_contact_regex)'::text as exclusion_policy,
  '(sittler|madison|athens|bishop)'::text as blocked_contact_regex;

