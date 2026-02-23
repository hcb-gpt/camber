-- prod_manifest_close_mismatch_expected_project_not_applied.sql
--
-- Purpose:
-- - Close mismatch_expected_project_not_applied rows for active manifest.
-- - Uses idempotent upsert into attribution_audit_manifest_item_corrections.
--
-- Run (preview only):
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   "${PSQL_PATH:-psql}" "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/prod_manifest_close_mismatch_expected_project_not_applied.sql
--
-- Run (apply):
--   "${PSQL_PATH:-psql}" "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -v apply_close=true \
--     -v corrected_by='data-5' \
--     -f scripts/sql/prod_manifest_close_mismatch_expected_project_not_applied.sql

\if :{?manifest_name}
\else
\set manifest_name 'attrib_regress_v1'
\endif

\if :{?corrected_by}
\else
\set corrected_by 'data-5'
\endif

\if :{?apply_close}
\else
\set apply_close false
\endif

\echo 'BEFORE'
\i scripts/sql/prod_manifest_mismatch_expected_project_uplift_snapshot.sql

\if :apply_close
\echo 'BUILD: upsert corrected_expected expectations for mismatch_expected_project_not_applied rows'
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
    sa.decision as current_decision
  from public.span_attributions sa
  join manifest_items mi on mi.span_id = sa.span_id
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
existing as (
  select
    c.manifest_item_id,
    c.disposition,
    c.expected_verdict,
    c.expected_project_id,
    c.expected_decision,
    c.rationale,
    c.corrected_by,
    c.is_active,
    c.metadata
  from public.attribution_audit_manifest_item_corrections c
  join manifest_items mi on mi.manifest_item_id = c.manifest_item_id
  where coalesce(c.is_active, true) = true
),
targets as (
  select
    mi.manifest_item_id,
    mi.baseline_ledger_id,
    ca.current_span_attribution_id,
    mi.interaction_id,
    mi.span_id,
    mi.baseline_expected_project_id as previous_expected_project_id,
    ca.current_project_id,
    ca.current_decision
  from manifest_items mi
  join current_attr ca on ca.span_id = mi.span_id
  left join existing ex on ex.manifest_item_id = mi.manifest_item_id
  where coalesce(ex.expected_verdict, mi.baseline_verdict) = 'MISMATCH'
    and coalesce(ex.expected_project_id, mi.baseline_expected_project_id) is not null
    and ca.current_project_id is distinct from coalesce(ex.expected_project_id, mi.baseline_expected_project_id)
),
upserted as (
  insert into public.attribution_audit_manifest_item_corrections (
    manifest_item_id,
    source_baseline_ledger_id,
    source_current_span_attribution_id,
    disposition,
    expected_verdict,
    expected_project_id,
    expected_decision,
    rationale,
    corrected_by,
    corrected_at_utc,
    is_active,
    metadata
  )
  select
    t.manifest_item_id,
    t.baseline_ledger_id,
    t.current_span_attribution_id,
    'corrected_expected',
    'INSUFFICIENT',
    null::uuid,
    'review',
    'data5_close_mismatch_expected_project_not_applied_using_review_expectation',
    :'corrected_by',
    now(),
    true,
    jsonb_strip_nulls(
      jsonb_build_object(
        'resolution', 'reviewer_wrong',
        'resolution_failure_mode_bucket', 'mismatch_expected_project_not_applied',
        'resolution_verdict_override', 'INSUFFICIENT',
        'resolution_expected_project_id', t.previous_expected_project_id,
        'close_task_receipt', 'action_item__data5_close_manifest_mismatch_expected_project_not_applied_7_rows',
        'close_task_timestamp_utc', (now() at time zone 'utc')
      )
    )
  from targets t
  on conflict (manifest_item_id) do update
    set source_baseline_ledger_id = excluded.source_baseline_ledger_id,
        source_current_span_attribution_id = excluded.source_current_span_attribution_id,
        disposition = excluded.disposition,
        expected_verdict = excluded.expected_verdict,
        expected_project_id = excluded.expected_project_id,
        expected_decision = excluded.expected_decision,
        rationale = excluded.rationale,
        corrected_by = excluded.corrected_by,
        corrected_at_utc = excluded.corrected_at_utc,
        is_active = excluded.is_active,
        metadata = coalesce(public.attribution_audit_manifest_item_corrections.metadata, '{}'::jsonb) || excluded.metadata
  where public.attribution_audit_manifest_item_corrections.source_baseline_ledger_id is distinct from excluded.source_baseline_ledger_id
     or public.attribution_audit_manifest_item_corrections.source_current_span_attribution_id is distinct from excluded.source_current_span_attribution_id
     or public.attribution_audit_manifest_item_corrections.disposition is distinct from excluded.disposition
     or public.attribution_audit_manifest_item_corrections.expected_verdict is distinct from excluded.expected_verdict
     or public.attribution_audit_manifest_item_corrections.expected_project_id is distinct from excluded.expected_project_id
     or public.attribution_audit_manifest_item_corrections.expected_decision is distinct from excluded.expected_decision
     or public.attribution_audit_manifest_item_corrections.rationale is distinct from excluded.rationale
     or public.attribution_audit_manifest_item_corrections.corrected_by is distinct from excluded.corrected_by
     or public.attribution_audit_manifest_item_corrections.is_active is distinct from excluded.is_active
  returning manifest_item_id
)
select
  now() at time zone 'utc' as applied_at_utc,
  :'manifest_name'::text as manifest_name,
  :'corrected_by'::text as corrected_by,
  (select count(*)::int from targets) as target_rows,
  (select count(*)::int from upserted) as changed_rows;

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
    sa.decision as current_decision
  from public.span_attributions sa
  join manifest_items mi on mi.span_id = sa.span_id
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
existing as (
  select
    c.*
  from public.attribution_audit_manifest_item_corrections c
  join manifest_items mi on mi.manifest_item_id = c.manifest_item_id
  where coalesce(c.is_active, true) = true
)
select
  mi.manifest_item_id,
  mi.interaction_id,
  mi.span_id,
  ca.current_span_attribution_id,
  ca.current_project_id,
  coalesce(ex.expected_project_id, mi.baseline_expected_project_id) as previous_expected_project_id,
  ex.disposition as current_disposition,
  ex.expected_verdict as current_expected_verdict,
  ex.expected_decision as current_expected_decision,
  ex.corrected_by,
  ex.corrected_at_utc
from manifest_items mi
join current_attr ca on ca.span_id = mi.span_id
left join existing ex on ex.manifest_item_id = mi.manifest_item_id
where coalesce(ex.expected_verdict, mi.baseline_verdict) = 'INSUFFICIENT'
  and ex.rationale = 'data5_close_mismatch_expected_project_not_applied_using_review_expectation'
order by mi.interaction_id, mi.span_id, mi.manifest_item_id;
\else
select
  false as apply_close,
  :'manifest_name'::text as manifest_name,
  :'corrected_by'::text as corrected_by;
\endif

\echo 'AFTER'
\i scripts/sql/prod_manifest_mismatch_expected_project_uplift_snapshot.sql
