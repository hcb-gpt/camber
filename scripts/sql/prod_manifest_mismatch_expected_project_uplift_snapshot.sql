-- prod_manifest_mismatch_expected_project_uplift_snapshot.sql
--
-- Purpose:
-- - Read-only snapshot for manifest mismatch closure verification.
-- - Primary focus bucket: mismatch_expected_project_not_applied.
--
-- Run:
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   scripts/query.sh --file scripts/sql/prod_manifest_mismatch_expected_project_uplift_snapshot.sql
--
-- Optional:
--   \set manifest_name 'attrib_regress_v1'

\if :{?manifest_name}
\else
\set manifest_name 'attrib_regress_v1'
\endif

\echo 'Q1: manifest regression headline snapshot'
with active_manifest as (
  select
    m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
manifest_items as (
  select
    mi.id as manifest_item_id,
    l.id as baseline_ledger_id,
    l.span_id,
    l.interaction_id,
    l.verdict as baseline_verdict,
    l.assigned_project_id as baseline_assigned_project_id,
    l.assigned_decision as baseline_assigned_decision,
    l.failure_tags as baseline_failure_tags,
    case
      when (l.top_candidates->0->>'project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (l.top_candidates->0->>'project_id')::uuid
      else null::uuid
    end as baseline_expected_project_id
  from public.attribution_audit_manifest_items mi
  join active_manifest am on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l on l.id = mi.ledger_id
),
current_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    sa.id as current_span_attribution_id,
    coalesce(sa.applied_project_id, sa.project_id) as current_project_id,
    sa.decision as current_decision,
    sa.confidence as current_confidence,
    sa.attributed_at as current_attributed_at
  from public.span_attributions sa
  join manifest_items mi on mi.span_id = sa.span_id
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
corrections as (
  select
    c.*
  from public.attribution_audit_manifest_item_corrections c
  join manifest_items mi on mi.manifest_item_id = c.manifest_item_id
  where coalesce(c.is_active, true) = true
),
evaluated as (
  select
    mi.manifest_item_id,
    mi.baseline_ledger_id,
    mi.interaction_id,
    mi.span_id,
    mi.baseline_verdict,
    mi.baseline_assigned_project_id,
    mi.baseline_assigned_decision,
    mi.baseline_failure_tags,
    mi.baseline_expected_project_id,
    ca.current_span_attribution_id,
    ca.current_project_id,
    ca.current_decision,
    ca.current_confidence,
    ca.current_attributed_at,
    c.disposition,
    c.expected_verdict,
    c.expected_project_id,
    c.expected_decision,
    c.corrected_by,
    c.corrected_at_utc,
    coalesce(c.expected_verdict, mi.baseline_verdict) as effective_expected_verdict,
    coalesce(c.expected_project_id, mi.baseline_expected_project_id) as effective_expected_project_id,
    case
      when coalesce(c.expected_verdict, mi.baseline_verdict) = 'MISMATCH' then
        case
          when coalesce(c.expected_project_id, mi.baseline_expected_project_id) is not null
               and ca.current_project_id = coalesce(c.expected_project_id, mi.baseline_expected_project_id)
            then 'PASS'
          when coalesce(c.expected_project_id, mi.baseline_expected_project_id) is null
               and ca.current_project_id is distinct from mi.baseline_assigned_project_id
            then 'PASS'
          else 'FAIL'
        end
      when coalesce(c.expected_verdict, mi.baseline_verdict) = 'INSUFFICIENT' then
        case
          when (
            coalesce(ca.current_decision, '') in ('review', 'none')
            or ca.current_project_id is null
          ) and exists (
            select 1
            from unnest(coalesce(mi.baseline_failure_tags, '{}'::text[])) as t(tag)
            where lower(t.tag) like '%pointer%'
               or lower(t.tag) like '%provenance%'
          ) then 'PASS'
          else 'FAIL'
        end
      when coalesce(c.expected_verdict, mi.baseline_verdict) = 'MATCH' then
        case
          when ca.current_project_id is not distinct from coalesce(c.expected_project_id, mi.baseline_expected_project_id)
               and coalesce(ca.current_decision, '') = 'assign'
            then 'PASS'
          else 'FAIL'
        end
      else 'FAIL'
    end as corrected_status
  from manifest_items mi
  left join current_attr ca on ca.span_id = mi.span_id
  left join corrections c on c.manifest_item_id = mi.manifest_item_id
),
labeled as (
  select
    e.*,
    case
      when e.corrected_status = 'PASS' then 'pass'
      when e.effective_expected_verdict = 'MISMATCH'
           and e.effective_expected_project_id is not null
           and e.current_project_id is distinct from e.effective_expected_project_id
        then 'mismatch_expected_project_not_applied'
      when e.effective_expected_verdict = 'MISMATCH'
           and e.effective_expected_project_id is null
           and e.current_project_id is not distinct from e.baseline_assigned_project_id
        then 'mismatch_assignment_unchanged_without_expected_project'
      when e.effective_expected_verdict = 'INSUFFICIENT'
           and not (
             coalesce(e.current_decision, '') in ('review', 'none')
             or e.current_project_id is null
           )
        then 'insufficient_not_demoted_to_review_or_none'
      when e.effective_expected_verdict = 'INSUFFICIENT'
           and (
             coalesce(e.current_decision, '') in ('review', 'none')
             or e.current_project_id is null
           )
           and not exists (
             select 1
             from unnest(coalesce(e.baseline_failure_tags, '{}'::text[])) as t(tag)
             where lower(t.tag) like '%pointer%'
                or lower(t.tag) like '%provenance%'
           )
        then 'insufficient_missing_pointer_or_provenance_tag'
      when e.effective_expected_verdict = 'MATCH'
           and (
             e.current_project_id is distinct from e.effective_expected_project_id
             or coalesce(e.current_decision, '') <> 'assign'
           )
        then 'match_regressed_from_baseline'
      else 'other'
    end as fail_reason
  from evaluated e
)
select
  now() at time zone 'utc' as generated_at_utc,
  :'manifest_name'::text as manifest_name,
  count(*)::int as total_manifest_items,
  count(*) filter (where corrected_status = 'PASS')::int as pass_count,
  count(*) filter (where corrected_status = 'FAIL')::int as fail_count,
  round(
    (count(*) filter (where corrected_status = 'PASS'))::numeric
    / nullif(count(*)::numeric, 0),
    4
  ) as pass_rate,
  count(*) filter (where fail_reason = 'mismatch_expected_project_not_applied')::int as mismatch_expected_project_not_applied_count,
  max(current_attributed_at) as latest_current_attributed_at_utc
from labeled;

\echo 'Q2: mismatch_expected_project_not_applied details'
with active_manifest as (
  select
    m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
manifest_items as (
  select
    mi.id as manifest_item_id,
    l.id as baseline_ledger_id,
    l.span_id,
    l.interaction_id,
    l.verdict as baseline_verdict,
    l.assigned_project_id as baseline_assigned_project_id,
    l.assigned_decision as baseline_assigned_decision,
    l.failure_tags as baseline_failure_tags,
    case
      when (l.top_candidates->0->>'project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (l.top_candidates->0->>'project_id')::uuid
      else null::uuid
    end as baseline_expected_project_id
  from public.attribution_audit_manifest_items mi
  join active_manifest am on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l on l.id = mi.ledger_id
),
current_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    sa.id as current_span_attribution_id,
    coalesce(sa.applied_project_id, sa.project_id) as current_project_id,
    sa.decision as current_decision,
    sa.confidence as current_confidence,
    sa.attributed_at as current_attributed_at
  from public.span_attributions sa
  join manifest_items mi on mi.span_id = sa.span_id
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
corrections as (
  select
    c.*
  from public.attribution_audit_manifest_item_corrections c
  join manifest_items mi on mi.manifest_item_id = c.manifest_item_id
  where coalesce(c.is_active, true) = true
),
evaluated as (
  select
    mi.manifest_item_id,
    mi.baseline_ledger_id,
    mi.interaction_id,
    mi.span_id,
    ca.current_span_attribution_id,
    ca.current_project_id,
    coalesce(c.expected_project_id, mi.baseline_expected_project_id) as expected_project_id,
    ca.current_decision,
    ca.current_confidence,
    c.disposition,
    c.corrected_by,
    c.corrected_at_utc,
    coalesce(c.expected_verdict, mi.baseline_verdict) as effective_expected_verdict
  from manifest_items mi
  left join current_attr ca on ca.span_id = mi.span_id
  left join corrections c on c.manifest_item_id = mi.manifest_item_id
)
select
  manifest_item_id,
  interaction_id,
  span_id,
  current_span_attribution_id,
  current_project_id,
  expected_project_id,
  current_decision,
  current_confidence,
  disposition,
  corrected_by,
  corrected_at_utc
from evaluated
where effective_expected_verdict = 'MISMATCH'
  and expected_project_id is not null
  and current_project_id is distinct from expected_project_id
order by interaction_id, span_id, manifest_item_id;

\echo 'Q3: fail_reason buckets'
with active_manifest as (
  select
    m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
manifest_items as (
  select
    mi.id as manifest_item_id,
    l.span_id,
    l.verdict as baseline_verdict,
    l.assigned_project_id as baseline_assigned_project_id,
    l.failure_tags as baseline_failure_tags,
    case
      when (l.top_candidates->0->>'project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (l.top_candidates->0->>'project_id')::uuid
      else null::uuid
    end as baseline_expected_project_id
  from public.attribution_audit_manifest_items mi
  join active_manifest am on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l on l.id = mi.ledger_id
),
current_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    coalesce(sa.applied_project_id, sa.project_id) as current_project_id,
    sa.decision as current_decision
  from public.span_attributions sa
  join manifest_items mi on mi.span_id = sa.span_id
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
corrections as (
  select
    c.*
  from public.attribution_audit_manifest_item_corrections c
  join manifest_items mi on mi.manifest_item_id = c.manifest_item_id
  where coalesce(c.is_active, true) = true
),
evaluated as (
  select
    mi.manifest_item_id,
    mi.baseline_assigned_project_id,
    mi.baseline_failure_tags,
    ca.current_project_id,
    ca.current_decision,
    coalesce(c.expected_verdict, mi.baseline_verdict) as effective_expected_verdict,
    coalesce(c.expected_project_id, mi.baseline_expected_project_id) as effective_expected_project_id,
    case
      when coalesce(c.expected_verdict, mi.baseline_verdict) = 'MISMATCH' then
        case
          when coalesce(c.expected_project_id, mi.baseline_expected_project_id) is not null
               and ca.current_project_id = coalesce(c.expected_project_id, mi.baseline_expected_project_id) then 'PASS'
          when coalesce(c.expected_project_id, mi.baseline_expected_project_id) is null
               and ca.current_project_id is distinct from mi.baseline_assigned_project_id then 'PASS'
          else 'FAIL'
        end
      when coalesce(c.expected_verdict, mi.baseline_verdict) = 'INSUFFICIENT' then
        case
          when (
            coalesce(ca.current_decision, '') in ('review', 'none')
            or ca.current_project_id is null
          ) and exists (
            select 1
            from unnest(coalesce(mi.baseline_failure_tags, '{}'::text[])) as t(tag)
            where lower(t.tag) like '%pointer%'
               or lower(t.tag) like '%provenance%'
          ) then 'PASS'
          else 'FAIL'
        end
      when coalesce(c.expected_verdict, mi.baseline_verdict) = 'MATCH' then
        case
          when ca.current_project_id is not distinct from coalesce(c.expected_project_id, mi.baseline_expected_project_id)
               and coalesce(ca.current_decision, '') = 'assign' then 'PASS'
          else 'FAIL'
        end
      else 'FAIL'
    end as corrected_status
  from manifest_items mi
  left join current_attr ca on ca.span_id = mi.span_id
  left join corrections c on c.manifest_item_id = mi.manifest_item_id
)
select
  case
    when corrected_status = 'PASS' then 'pass'
    when effective_expected_verdict = 'MISMATCH'
         and effective_expected_project_id is not null
         and current_project_id is distinct from effective_expected_project_id
      then 'mismatch_expected_project_not_applied'
    when effective_expected_verdict = 'MISMATCH'
         and effective_expected_project_id is null
         and current_project_id is not distinct from baseline_assigned_project_id
      then 'mismatch_assignment_unchanged_without_expected_project'
    when effective_expected_verdict = 'INSUFFICIENT'
         and not (
           coalesce(current_decision, '') in ('review', 'none')
           or current_project_id is null
         )
      then 'insufficient_not_demoted_to_review_or_none'
    else 'other'
  end as fail_reason,
  count(*)::int as item_count
from evaluated
group by fail_reason
order by item_count desc, fail_reason;
