-- P0 attribution baseline + compounding-loop gate packet
-- Receipt target:
--   completion__p0_attrib__baseline_metrics_and_compounding_loop_gate__20260228
--
-- Usage:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/p0_attrib_baseline_compounding_loop_gate_20260228.sql

\echo 'Q1A) Baseline snapshot: v_metrics_attribution_anchor_quality (latest)'
select
  measured_at_utc,
  total_assignments_24h,
  anchored_assignments_24h,
  unanchored_assignments_24h,
  anchored_assign_rate,
  unanchored_assign_rate
from public.v_metrics_attribution_anchor_quality
order by measured_at_utc desc
limit 1;

\echo 'Q1B) Baseline snapshot: v_attribution_audit_disagreement_headline_7d'
select
  generated_at_utc,
  reviewed_total_7d,
  match_count_7d,
  mismatch_count_7d,
  insufficient_count_7d,
  disagreement_count_7d,
  disagreement_rate_7d,
  leakage_violations_7d,
  pointer_quality_violations_7d
from public.v_attribution_audit_disagreement_headline_7d;

\echo 'Q1C) Baseline snapshot: v_attribution_audit_failure_buckets_daily (last 7d rollup)'
select
  failure_tag,
  sum(bucket_count)::int as failures_7d
from public.v_attribution_audit_failure_buckets_daily
where day_utc >= current_date - interval '7 days'
group by failure_tag
order by failures_7d desc, failure_tag
limit 20;

\echo 'Q1D) Baseline snapshot: v_attribution_failure_compounding_loop_7d (bucket rollup)'
select
  failure_mode_bucket,
  sum(failures_7d)::int as failures_7d,
  sum(unresolved_7d)::int as unresolved_7d,
  max(last_seen_7d_utc) as last_seen_utc
from public.v_attribution_failure_compounding_loop_7d
group by failure_mode_bucket
order by failures_7d desc, unresolved_7d desc, failure_mode_bucket
limit 10;

\echo 'Q1E) Baseline snapshot: v_review_coverage_gaps summary + oldest cases'
select
  count(*)::int as review_coverage_gaps,
  min(attributed_at) as oldest_gap_at,
  max(attributed_at) as newest_gap_at
from public.v_review_coverage_gaps;

select
  interaction_id,
  span_id,
  span_index,
  decision,
  needs_review,
  attributed_at
from public.v_review_coverage_gaps
order by attributed_at asc
limit 20;

\echo 'Q2A) Top 3 failure buckets (7d) + representative REAL_DATA_POINTER rows'
with bucket_rollup as (
  select
    failure_mode_bucket,
    sum(failures_7d)::int as failures_7d,
    sum(unresolved_7d)::int as unresolved_7d,
    max(last_seen_7d_utc) as last_seen_utc
  from public.v_attribution_failure_compounding_loop_7d
  group by failure_mode_bucket
),
top3 as (
  select
    failure_mode_bucket,
    failures_7d,
    unresolved_7d,
    last_seen_utc
  from bucket_rollup
  order by failures_7d desc, unresolved_7d desc, failure_mode_bucket
  limit 3
),
rep as (
  select
    l.failure_mode_bucket,
    l.interaction_id,
    l.span_id,
    l.id as ledger_id,
    l.attribution_source,
    l.assigned_confidence,
    l.created_at,
    row_number() over (
      partition by l.failure_mode_bucket
      order by l.created_at desc, l.id desc
    ) as rn
  from public.attribution_audit_ledger l
  join top3 t on t.failure_mode_bucket = l.failure_mode_bucket
)
select
  t.failure_mode_bucket,
  t.failures_7d,
  t.unresolved_7d,
  t.last_seen_utc,
  r.interaction_id as real_data_pointer_interaction_id,
  r.span_id as real_data_pointer_span_id,
  r.ledger_id as real_data_pointer_ledger_id,
  r.attribution_source,
  r.assigned_confidence,
  r.created_at as pointer_created_at
from top3 t
left join rep r
  on r.failure_mode_bucket = t.failure_mode_bucket
 and r.rn = 1
order by t.failures_7d desc, t.failure_mode_bucket;

\echo 'Q2B) Falsification check #1: insufficient_provenance_pointer_quality'
with bucket_rows as (
  select *
  from public.attribution_audit_ledger
  where failure_mode_bucket = 'insufficient_provenance_pointer_quality'
    and created_at >= now() - interval '7 days'
)
select
  count(*)::int as rows_7d,
  count(*) filter (where coalesce(pointer_quality_violation, false))::int as pointer_quality_violations_7d,
  count(*) filter (where coalesce(array_length(evidence_event_ids, 1), 0) = 0)::int as missing_evidence_event_ids_7d,
  count(*) filter (
    where case
      when evidence_pointers is null then 0
      when jsonb_typeof(evidence_pointers) = 'array' then jsonb_array_length(evidence_pointers)
      else 0
    end = 0
  )::int as missing_evidence_pointers_7d,
  'falsify when violations + missing pointers trend to ~0'::text as falsification_rule
from bucket_rows;

\echo 'Q2C) Falsification check #2: hard_drop_pipeline_failed'
with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    coalesce(cs.created_at, now()) as span_created_at_utc
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
    and cs.interaction_id not like 'cll_SHADOW%'
    and cs.interaction_id not like 'cll_RACECHK%'
    and cs.interaction_id not like 'cll_DEV%'
    and cs.interaction_id not like 'cll_CHAIN%'
),
latest_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    sa.decision,
    coalesce(sa.needs_review, false) as needs_review
  from public.span_attributions sa
  order by sa.span_id, coalesce(sa.applied_at_utc, sa.attributed_at, now()) desc, sa.id desc
),
latest_pending_review as (
  select distinct on (rq.span_id)
    rq.span_id,
    rq.created_at as review_created_at_utc
  from public.review_queue rq
  where rq.status = 'pending'
  order by rq.span_id, rq.created_at desc, rq.id desc
),
pending_spans as (
  select
    s.span_id,
    s.interaction_id,
    la.decision,
    la.needs_review,
    (rq.span_id is not null) as has_pending_review,
    extract(epoch from (
      now() - coalesce(rq.review_created_at_utc, s.span_created_at_utc, now())
    )) / 3600.0 as age_hours
  from active_spans s
  left join latest_attr la on la.span_id = s.span_id
  left join latest_pending_review rq on rq.span_id = s.span_id
  where (
    la.span_id is null
    or la.decision is null
    or la.decision = 'review'
    or la.needs_review = true
  )
)
select
  count(*) filter (where has_pending_review and age_hours >= 24)::int as pending_over_24h,
  count(*) filter (where has_pending_review and age_hours < 24)::int as pending_under_24h,
  count(*) filter (where not has_pending_review)::int as uncovered_without_review_queue,
  array(
    select distinct p2.interaction_id
    from pending_spans p2
    where not p2.has_pending_review
    order by p2.interaction_id
    limit 10
  ) as sample_uncovered_interaction_ids,
  'falsify when uncovered_without_review_queue=0 and pending_over_24h trends down to 0'::text as falsification_rule
from pending_spans;

\echo 'Q2D) Falsification check #3: test_fixture_hard_drop_pending_window'
with fixture_rows as (
  select
    interaction_id
  from public.attribution_audit_ledger
  where failure_mode_bucket = 'test_fixture_hard_drop_pending_window'
    and created_at >= now() - interval '7 days'
)
select
  count(*)::int as rows_7d,
  count(*) filter (
    where interaction_id like 'cll_SMS_PROBE_%'
       or interaction_id like 'cll_VP_%'
  )::int as fixture_like_rows_7d,
  count(*) filter (
    where not (
      interaction_id like 'cll_SMS_PROBE_%'
      or interaction_id like 'cll_VP_%'
    )
  )::int as non_fixture_like_rows_7d,
  'falsify when non_fixture_like_rows_7d=0 (pure fixture noise) or bucket fully removed'::text as falsification_rule
from fixture_rows;

\echo 'Q3A) Compounding loop check: model-attrib vs human-reviewed span cohorts (latest per span, 7d)'
with latest_sa as (
  select distinct on (sa.span_id)
    sa.span_id,
    cs.interaction_id,
    coalesce(sa.applied_at_utc, sa.attributed_at) as attrib_ts,
    sa.attribution_source,
    sa.attribution_lock,
    sa.decision,
    sa.needs_review,
    sa.confidence,
    coalesce(sa.applied_project_id, sa.project_id) as resolved_project_id
  from public.span_attributions sa
  join public.conversation_spans cs on cs.id = sa.span_id
  where coalesce(cs.is_superseded, false) = false
    and coalesce(sa.applied_at_utc, sa.attributed_at) >= now() - interval '7 days'
  order by sa.span_id, coalesce(sa.applied_at_utc, sa.attributed_at) desc, sa.id desc
)
select
  case
    when attribution_lock = 'human'
      or attribution_source in (
        'review_resolve',
        'gt_apply',
        'manual',
        'human_override',
        'admin_reseed_human_lock_carryforward'
      )
    then 'human_reviewed'
    else 'model_attrib'
  end as source_group,
  count(*)::int as spans_7d,
  count(*) filter (where coalesce(confidence, 0) >= 0.8)::int as confidence_ge_08,
  count(*) filter (where coalesce(confidence, 0) >= 0.9)::int as confidence_ge_09,
  count(*) filter (where decision = 'review' or needs_review = true)::int as needs_review_rows,
  count(*) filter (where resolved_project_id is not null)::int as with_project_id
from latest_sa
group by 1
order by spans_7d desc;

\echo 'Q3B) Affinity-source observability: rows touched in correspondent_project_affinity (7d)'
select
  source,
  count(*)::int as rows_updated_7d
from public.correspondent_project_affinity
where updated_at >= now() - interval '7 days'
group by source
order by rows_updated_7d desc, source
limit 25;

\echo 'Q3C) Affinity-source guard check for expected attribution writers'
select
  count(*) filter (where source = 'router_attribution')::int as source_router_attribution_rows,
  count(*) filter (where source = 'review_queue')::int as source_review_queue_rows,
  count(*) filter (where source = 'human_override')::int as source_human_override_rows
from public.correspondent_project_affinity;

\echo 'Q3D) Recommended gate parameters from current health snapshot'
with anchor as (
  select
    anchored_assign_rate,
    unanchored_assign_rate
  from public.v_metrics_attribution_anchor_quality
  order by measured_at_utc desc
  limit 1
),
headline as (
  select
    reviewed_total_7d,
    disagreement_rate_7d
  from public.v_attribution_audit_disagreement_headline_7d
  limit 1
),
comp as (
  select
    sum(failures_7d)::int as failures_7d,
    sum(unresolved_7d)::int as unresolved_7d
  from public.v_attribution_failure_compounding_loop_7d
)
select
  a.anchored_assign_rate,
  a.unanchored_assign_rate,
  h.reviewed_total_7d,
  h.disagreement_rate_7d,
  c.failures_7d,
  c.unresolved_7d,
  case
    when h.disagreement_rate_7d >= 0.50
      or a.unanchored_assign_rate >= 0.40
      or c.unresolved_7d > 0
    then 'HUMAN_ONLY'
    else 'HYBRID'
  end as recommended_gate_mode,
  case
    when h.disagreement_rate_7d >= 0.50
      or a.unanchored_assign_rate >= 0.40
      or c.unresolved_7d > 0
    then 0.93
    else 0.85
  end as recommended_model_min_confidence,
  'Allow affinity write only for human/gt-reviewed resolutions while gate_mode=HUMAN_ONLY'::text as recommended_rule_primary,
  'If gate_mode switches to HYBRID: require model confidence >= recommended_model_min_confidence and no open review coverage gap'::text as recommended_rule_secondary
from anchor a
cross join headline h
cross join comp c;
