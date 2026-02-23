-- prod_failure_compounding_loop_preview.sql
--
-- Purpose:
-- - Read-only preview of compounding-loop metrics before migration apply.
-- - Quantifies failure_mode -> pattern -> regression_key -> hardened_fix_lane.
--
-- Run:
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   scripts/query.sh --file scripts/sql/prod_failure_compounding_loop_preview.sql

\echo 'Q1: compounding-loop headline (7d)'
with active_manifest as (
  select m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
),
manifest_ledger as (
  select distinct mi.ledger_id
  from public.attribution_audit_manifest_items mi
  join active_manifest am
    on am.manifest_id = mi.manifest_id
),
ledger_base as (
  select
    l.id as ledger_id,
    l.created_at,
    l.interaction_id,
    l.span_id,
    l.verdict,
    coalesce(l.failure_mode_bucket, 'unbucketed') as failure_mode_bucket,
    coalesce(nullif(trim(lower(l.failure_detail)), ''), '<none>') as failure_detail_raw,
    coalesce(l.attribution_source, '<unknown>') as attribution_source,
    coalesce(l.evidence_tier, -1) as evidence_tier,
    case
      when l.assigned_confidence is null then 'null'
      when l.assigned_confidence < 0.50 then 'lt_050'
      when l.assigned_confidence < 0.70 then '050_070'
      when l.assigned_confidence < 0.85 then '070_085'
      else 'ge_085'
    end as confidence_band,
    l.resolved_at,
    (ml.ledger_id is not null) as in_active_manifest
  from public.attribution_audit_ledger l
  left join manifest_ledger ml
    on ml.ledger_id = l.id
  where l.verdict in ('MISMATCH', 'INSUFFICIENT')
    and l.created_at >= now() - interval '14 days'
),
patterned as (
  select
    b.*,
    case
      when b.failure_mode_bucket = 'hard_drop_pipeline_failed'
        then 'pipeline_coverage_gap'
      when b.failure_mode_bucket = 'insufficient_provenance_pointer_quality'
        and b.failure_detail_raw like '%reviewer_llm_unavailable%'
        then 'pointer_missing_reviewer_llm'
      when b.failure_mode_bucket = 'insufficient_provenance_pointer_quality'
        and b.failure_detail_raw like '%as_of_project_context%'
        then 'pointer_missing_known_as_of'
      when b.failure_mode_bucket = 'insufficient_provenance_pointer_quality'
        and b.failure_detail_raw like '%evidence_events_or_claim_pointers%'
        then 'pointer_missing_evidence_events'
      when b.failure_mode_bucket = 'location_anchor_overweight'
        then 'scoring_location_anchor_overweight'
      when b.failure_mode_bucket = 'multi_project_span_ambiguity'
        then 'scoring_multi_project_ambiguity'
      when b.failure_mode_bucket = 'unbucketed'
        then 'unbucketed_needs_classification'
      else b.failure_mode_bucket
    end as pattern_family,
    left(
      regexp_replace(
        regexp_replace(
          b.failure_detail_raw,
          '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
          '<uuid>',
          'gi'
        ),
        '\s+',
        ' ',
        'g'
      ),
      220
    ) as pattern_signature
  from ledger_base b
),
windowed as (
  select
    p.*,
    case
      when p.created_at >= now() - interval '7 days' then 'current'
      when p.created_at >= now() - interval '14 days'
       and p.created_at < now() - interval '7 days' then 'prior'
      else null
    end as window_bucket
  from patterned p
),
aggregated as (
  select
    w.failure_mode_bucket,
    w.pattern_family,
    w.pattern_signature,
    w.attribution_source,
    w.evidence_tier,
    w.confidence_band,
    count(*) filter (where w.window_bucket = 'current')::int as failures_7d,
    count(*) filter (where w.window_bucket = 'prior')::int as failures_prev_7d,
    count(distinct w.interaction_id) filter (where w.window_bucket = 'current')::int as interactions_7d,
    count(distinct w.span_id) filter (where w.window_bucket = 'current')::int as spans_7d,
    count(*) filter (where w.window_bucket = 'current' and w.resolved_at is null)::int as unresolved_7d,
    count(*) filter (where w.window_bucket = 'current' and w.resolved_at is not null)::int as resolved_7d,
    count(*) filter (where w.window_bucket = 'current' and w.in_active_manifest)::int as in_active_manifest_7d
  from windowed w
  group by
    w.failure_mode_bucket,
    w.pattern_family,
    w.pattern_signature,
    w.attribution_source,
    w.evidence_tier,
    w.confidence_band
),
ranked as (
  select
    a.*,
    (a.failures_7d - a.failures_prev_7d)::int as delta_failures_7d,
    greatest(a.failures_7d - a.in_active_manifest_7d, 0)::int as regression_gap_7d,
    case
      when a.failures_7d = 0 then 0::numeric
      else round(a.unresolved_7d::numeric / a.failures_7d::numeric, 4)
    end as unresolved_rate_7d,
    dense_rank() over (
      order by
        a.unresolved_7d desc,
        a.failures_7d desc,
        a.pattern_family,
        a.pattern_signature
    ) as regression_rank_7d
  from aggregated a
  where a.failures_7d > 0
)
select
  now() at time zone 'utc' as generated_at_utc,
  sum(failures_7d)::int as total_failures_7d,
  sum(unresolved_7d)::int as total_unresolved_7d,
  sum(in_active_manifest_7d)::int as total_in_active_manifest_7d,
  sum(regression_gap_7d)::int as total_regression_gap_7d,
  count(*)::int as active_patterns_7d
from ranked;

\echo 'Q2: top compounding patterns by unresolved load'
with active_manifest as (
  select m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
),
manifest_ledger as (
  select distinct mi.ledger_id
  from public.attribution_audit_manifest_items mi
  join active_manifest am
    on am.manifest_id = mi.manifest_id
),
ledger_base as (
  select
    l.id as ledger_id,
    l.created_at,
    l.interaction_id,
    l.span_id,
    l.verdict,
    coalesce(l.failure_mode_bucket, 'unbucketed') as failure_mode_bucket,
    coalesce(nullif(trim(lower(l.failure_detail)), ''), '<none>') as failure_detail_raw,
    coalesce(l.attribution_source, '<unknown>') as attribution_source,
    coalesce(l.evidence_tier, -1) as evidence_tier,
    case
      when l.assigned_confidence is null then 'null'
      when l.assigned_confidence < 0.50 then 'lt_050'
      when l.assigned_confidence < 0.70 then '050_070'
      when l.assigned_confidence < 0.85 then '070_085'
      else 'ge_085'
    end as confidence_band,
    l.resolved_at,
    (ml.ledger_id is not null) as in_active_manifest
  from public.attribution_audit_ledger l
  left join manifest_ledger ml
    on ml.ledger_id = l.id
  where l.verdict in ('MISMATCH', 'INSUFFICIENT')
    and l.created_at >= now() - interval '14 days'
),
patterned as (
  select
    b.*,
    case
      when b.failure_mode_bucket = 'hard_drop_pipeline_failed'
        then 'pipeline_coverage_gap'
      when b.failure_mode_bucket = 'insufficient_provenance_pointer_quality'
        and b.failure_detail_raw like '%reviewer_llm_unavailable%'
        then 'pointer_missing_reviewer_llm'
      when b.failure_mode_bucket = 'insufficient_provenance_pointer_quality'
        and b.failure_detail_raw like '%as_of_project_context%'
        then 'pointer_missing_known_as_of'
      when b.failure_mode_bucket = 'insufficient_provenance_pointer_quality'
        and b.failure_detail_raw like '%evidence_events_or_claim_pointers%'
        then 'pointer_missing_evidence_events'
      when b.failure_mode_bucket = 'location_anchor_overweight'
        then 'scoring_location_anchor_overweight'
      when b.failure_mode_bucket = 'multi_project_span_ambiguity'
        then 'scoring_multi_project_ambiguity'
      when b.failure_mode_bucket = 'unbucketed'
        then 'unbucketed_needs_classification'
      else b.failure_mode_bucket
    end as pattern_family,
    left(
      regexp_replace(
        regexp_replace(
          b.failure_detail_raw,
          '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
          '<uuid>',
          'gi'
        ),
        '\s+',
        ' ',
        'g'
      ),
      220
    ) as pattern_signature
  from ledger_base b
),
windowed as (
  select
    p.*,
    case
      when p.created_at >= now() - interval '7 days' then 'current'
      when p.created_at >= now() - interval '14 days'
       and p.created_at < now() - interval '7 days' then 'prior'
      else null
    end as window_bucket
  from patterned p
),
aggregated as (
  select
    w.failure_mode_bucket,
    w.pattern_family,
    w.pattern_signature,
    w.attribution_source,
    w.evidence_tier,
    w.confidence_band,
    count(*) filter (where w.window_bucket = 'current')::int as failures_7d,
    count(*) filter (where w.window_bucket = 'prior')::int as failures_prev_7d,
    count(distinct w.interaction_id) filter (where w.window_bucket = 'current')::int as interactions_7d,
    count(distinct w.span_id) filter (where w.window_bucket = 'current')::int as spans_7d,
    count(*) filter (where w.window_bucket = 'current' and w.resolved_at is null)::int as unresolved_7d,
    count(*) filter (where w.window_bucket = 'current' and w.resolved_at is not null)::int as resolved_7d,
    count(*) filter (where w.window_bucket = 'current' and w.in_active_manifest)::int as in_active_manifest_7d
  from windowed w
  group by
    w.failure_mode_bucket,
    w.pattern_family,
    w.pattern_signature,
    w.attribution_source,
    w.evidence_tier,
    w.confidence_band
),
ranked as (
  select
    a.*,
    (a.failures_7d - a.failures_prev_7d)::int as delta_failures_7d,
    greatest(a.failures_7d - a.in_active_manifest_7d, 0)::int as regression_gap_7d,
    case
      when a.failures_7d = 0 then 0::numeric
      else round(a.unresolved_7d::numeric / a.failures_7d::numeric, 4)
    end as unresolved_rate_7d,
    dense_rank() over (
      order by
        a.unresolved_7d desc,
        a.failures_7d desc,
        a.pattern_family,
        a.pattern_signature
    ) as regression_rank_7d
  from aggregated a
  where a.failures_7d > 0
)
select
  failure_mode_bucket,
  pattern_family,
  pattern_signature,
  attribution_source,
  evidence_tier,
  confidence_band,
  failures_7d,
  failures_prev_7d,
  delta_failures_7d,
  interactions_7d,
  spans_7d,
  unresolved_7d,
  resolved_7d,
  unresolved_rate_7d,
  in_active_manifest_7d,
  regression_gap_7d,
  regression_rank_7d,
  case
    when pattern_family = 'pointer_missing_known_as_of'
      then 'world_model_known_as_of'
    when pattern_family = 'pointer_missing_evidence_events'
      then 'provenance_pointer_generation'
    when pattern_family = 'pointer_missing_reviewer_llm'
      then 'auditor_runtime_resilience'
    when pattern_family = 'pipeline_coverage_gap'
      then 'pipeline_coverage_stopline'
    when pattern_family = 'scoring_location_anchor_overweight'
      then 'scoring_anchor_rebalance'
    when pattern_family = 'scoring_multi_project_ambiguity'
      then 'multi_project_disambiguation'
    when pattern_family = 'unbucketed_needs_classification'
      then 'failure_taxonomy_hardening'
    else 'general_attribution_hardening'
  end as hardened_fix_lane,
  md5(
    concat_ws(
      '|',
      failure_mode_bucket,
      pattern_family,
      pattern_signature,
      attribution_source,
      evidence_tier::text,
      confidence_band
    )
  ) as regression_key
from ranked
order by unresolved_7d desc, failures_7d desc, pattern_family, pattern_signature
limit 15;
