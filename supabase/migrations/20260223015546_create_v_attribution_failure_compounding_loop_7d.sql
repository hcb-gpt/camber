create or replace view public.v_attribution_failure_compounding_loop_7d as
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
    l.resolution,
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
    count(*) filter (where w.window_bucket = 'current' and w.in_active_manifest)::int as in_active_manifest_7d,
    min(w.created_at) filter (where w.window_bucket = 'current') as first_seen_7d_utc,
    max(w.created_at) filter (where w.window_bucket = 'current') as last_seen_7d_utc
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
    ) as regression_rank_7d,
    md5(
      concat_ws(
        '|',
        a.failure_mode_bucket,
        a.pattern_family,
        a.pattern_signature,
        a.attribution_source,
        a.evidence_tier::text,
        a.confidence_band
      )
    ) as regression_key
  from aggregated a
  where a.failures_7d > 0
)
select
  now() at time zone 'utc' as generated_at_utc,
  now() - interval '7 days' as window_start_utc,
  now() as window_end_utc,
  r.failure_mode_bucket,
  r.pattern_family,
  r.pattern_signature,
  r.attribution_source,
  r.evidence_tier,
  r.confidence_band,
  r.failures_7d,
  r.failures_prev_7d,
  r.delta_failures_7d,
  r.interactions_7d,
  r.spans_7d,
  r.unresolved_7d,
  r.resolved_7d,
  r.unresolved_rate_7d,
  r.in_active_manifest_7d,
  r.regression_gap_7d,
  r.first_seen_7d_utc,
  r.last_seen_7d_utc,
  r.regression_rank_7d,
  r.regression_key,
  case
    when r.pattern_family = 'pointer_missing_known_as_of'
      then 'world_model_known_as_of'
    when r.pattern_family = 'pointer_missing_evidence_events'
      then 'provenance_pointer_generation'
    when r.pattern_family = 'pointer_missing_reviewer_llm'
      then 'auditor_runtime_resilience'
    when r.pattern_family = 'pipeline_coverage_gap'
      then 'pipeline_coverage_stopline'
    when r.pattern_family = 'scoring_location_anchor_overweight'
      then 'scoring_anchor_rebalance'
    when r.pattern_family = 'scoring_multi_project_ambiguity'
      then 'multi_project_disambiguation'
    when r.pattern_family = 'unbucketed_needs_classification'
      then 'failure_taxonomy_hardening'
    else 'general_attribution_hardening'
  end as hardened_fix_lane,
  case
    when r.pattern_family = 'pointer_missing_known_as_of'
      then 'Fail closed when as-of project facts are absent; add known-as-of fact hydration before assignment.'
    when r.pattern_family = 'pointer_missing_evidence_events'
      then 'Require claim-pointer/evidence-event anchors for non-review assignment.'
    when r.pattern_family = 'pointer_missing_reviewer_llm'
      then 'Route reviewer LLM outages to deterministic review fallback, never silent pass-through.'
    when r.pattern_family = 'pipeline_coverage_gap'
      then 'Backfill missing span_attributions and enforce stopline on uncovered active spans.'
    when r.pattern_family = 'scoring_location_anchor_overweight'
      then 'Reduce location-anchor weight when competing project evidence exists.'
    when r.pattern_family = 'scoring_multi_project_ambiguity'
      then 'Force review when margin is below ambiguity threshold and multiple projects overlap.'
    when r.pattern_family = 'unbucketed_needs_classification'
      then 'Classify unbucketed failures into stable taxonomy buckets before triage.'
    else 'Apply bucket-specific remediation and keep weekly deltas trending down.'
  end as suggested_hardened_fix,
  case
    when r.regression_gap_7d > 0 then 'seed_or_expand_manifest'
    when r.unresolved_7d > 0 then 'apply_fix_and_close_open_items'
    else 'monitor_delta'
  end as next_action
from ranked r;

comment on view public.v_attribution_failure_compounding_loop_7d is
  'Compounding loop scoreboard for attribution reliability: failure_mode -> pattern -> regression_key -> hardened fix lane, with 7d trend and manifest coverage gap.';

grant select on public.v_attribution_failure_compounding_loop_7d to anon, authenticated, service_role;;
