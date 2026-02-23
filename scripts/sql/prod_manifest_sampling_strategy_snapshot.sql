-- prod_manifest_sampling_strategy_snapshot.sql
--
-- Purpose:
-- - Snapshot manifest coverage needed for strategy design.
-- - Quantify distribution by interaction/project/failure_mode/audit_sample_id.
-- - Flag project and failure-mode coverage gaps.
--
-- Run:
--   cd /Users/chadbarlow/gh/hcb-gpt/camber-calls
--   source scripts/load-env.sh >/dev/null
--   scripts/query.sh --file scripts/sql/prod_manifest_sampling_strategy_snapshot.sql
--
-- Optional vars:
--   \set manifest_name 'attrib_regress_v1'
--   \set underrep_threshold 2

\if :{?manifest_name}
\else
\set manifest_name 'attrib_regress_v1'
\endif

\if :{?underrep_threshold}
\else
\set underrep_threshold 2
\endif

\echo 'Q1: distribution by interaction, project, failure_mode_bucket, audit_sample_id'
with active_manifest as (
  select m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
base_items as (
  select
    mi.id as manifest_item_id,
    l.id as ledger_id,
    l.interaction_id,
    l.assigned_project_id,
    l.expected_project_id as ledger_expected_project_id,
    l.resolution_expected_project_id,
    l.failure_mode_bucket,
    l.audit_sample_id,
    l.top_candidates
  from public.attribution_audit_manifest_items mi
  join active_manifest am
    on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l
    on l.id = mi.ledger_id
),
active_corrections as (
  select
    c.manifest_item_id,
    c.expected_project_id as correction_expected_project_id
  from public.attribution_audit_manifest_item_corrections c
  where coalesce(c.is_active, true) = true
),
effective_items as (
  select
    b.manifest_item_id,
    b.interaction_id,
    b.failure_mode_bucket,
    b.audit_sample_id,
    coalesce(
      c.correction_expected_project_id,
      b.resolution_expected_project_id,
      b.ledger_expected_project_id,
      case
        when (b.top_candidates->0->>'project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then (b.top_candidates->0->>'project_id')::uuid
        else null::uuid
      end,
      b.assigned_project_id
    ) as effective_project_id
  from base_items b
  left join active_corrections c
    on c.manifest_item_id = b.manifest_item_id
)
select
  ei.interaction_id,
  ei.effective_project_id as project_id,
  coalesce(p.name, '<unmapped_project>') as project_name,
  coalesce(ei.failure_mode_bucket, '<null>') as failure_mode_bucket,
  coalesce(ei.audit_sample_id::text, '<null>') as audit_sample_id,
  count(*)::int as manifest_item_count
from effective_items ei
left join public.projects p
  on p.id = ei.effective_project_id
group by
  ei.interaction_id,
  ei.effective_project_id,
  coalesce(p.name, '<unmapped_project>'),
  coalesce(ei.failure_mode_bucket, '<null>'),
  coalesce(ei.audit_sample_id::text, '<null>')
order by manifest_item_count desc, interaction_id, project_name, failure_mode_bucket, audit_sample_id;

\echo 'Q2: active project coverage (status=active) and zero-coverage gaps'
with active_manifest as (
  select m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
base_items as (
  select
    mi.id as manifest_item_id,
    l.assigned_project_id,
    l.expected_project_id as ledger_expected_project_id,
    l.resolution_expected_project_id,
    l.top_candidates
  from public.attribution_audit_manifest_items mi
  join active_manifest am
    on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l
    on l.id = mi.ledger_id
),
active_corrections as (
  select
    c.manifest_item_id,
    c.expected_project_id as correction_expected_project_id
  from public.attribution_audit_manifest_item_corrections c
  where coalesce(c.is_active, true) = true
),
effective_items as (
  select
    coalesce(
      c.correction_expected_project_id,
      b.resolution_expected_project_id,
      b.ledger_expected_project_id,
      case
        when (b.top_candidates->0->>'project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then (b.top_candidates->0->>'project_id')::uuid
        else null::uuid
      end,
      b.assigned_project_id
    ) as effective_project_id
  from base_items b
  left join active_corrections c
    on c.manifest_item_id = b.manifest_item_id
),
active_projects as (
  select p.id, p.name
  from public.projects p
  where p.status = 'active'
),
project_counts as (
  select
    ei.effective_project_id as project_id,
    count(*)::int as manifest_item_count
  from effective_items ei
  group by ei.effective_project_id
)
select
  ap.id as project_id,
  ap.name as project_name,
  coalesce(pc.manifest_item_count, 0)::int as manifest_item_count,
  case
    when coalesce(pc.manifest_item_count, 0) = 0 then 'GAP_ZERO_COVERAGE'
    when coalesce(pc.manifest_item_count, 0) < (:'underrep_threshold')::int then 'GAP_UNDER_THRESHOLD'
    else 'OK'
  end as coverage_status
from active_projects ap
left join project_counts pc
  on pc.project_id = ap.id
order by manifest_item_count asc, project_name;

\echo 'Q3: failure_mode_bucket distribution and under-represented buckets'
with active_manifest as (
  select m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
manifest_failures as (
  select
    coalesce(l.failure_mode_bucket, '<null>') as failure_mode_bucket
  from public.attribution_audit_manifest_items mi
  join active_manifest am
    on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l
    on l.id = mi.ledger_id
)
select
  mf.failure_mode_bucket,
  count(*)::int as manifest_item_count,
  round(
    100.0 * count(*)::numeric / nullif(sum(count(*)) over (), 0),
    2
  ) as pct_of_manifest,
  case
    when count(*) < (:'underrep_threshold')::int then 'UNDER_REPRESENTED'
    else 'OK'
  end as representation_status
from manifest_failures mf
group by mf.failure_mode_bucket
order by manifest_item_count asc, mf.failure_mode_bucket;

\echo 'Q4: headline snapshot'
with active_manifest as (
  select m.id as manifest_id
  from public.attribution_audit_manifest m
  where m.is_active = true
    and m.name = :'manifest_name'
  order by m.created_at desc
  limit 1
),
base_items as (
  select
    mi.id as manifest_item_id,
    l.assigned_project_id,
    l.expected_project_id as ledger_expected_project_id,
    l.resolution_expected_project_id,
    l.failure_mode_bucket,
    l.top_candidates
  from public.attribution_audit_manifest_items mi
  join active_manifest am
    on am.manifest_id = mi.manifest_id
  join public.attribution_audit_ledger l
    on l.id = mi.ledger_id
),
active_corrections as (
  select
    c.manifest_item_id,
    c.expected_project_id as correction_expected_project_id
  from public.attribution_audit_manifest_item_corrections c
  where coalesce(c.is_active, true) = true
),
effective_items as (
  select
    b.manifest_item_id,
    coalesce(
      c.correction_expected_project_id,
      b.resolution_expected_project_id,
      b.ledger_expected_project_id,
      case
        when (b.top_candidates->0->>'project_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then (b.top_candidates->0->>'project_id')::uuid
        else null::uuid
      end,
      b.assigned_project_id
    ) as effective_project_id,
    coalesce(b.failure_mode_bucket, '<null>') as failure_mode_bucket
  from base_items b
  left join active_corrections c
    on c.manifest_item_id = b.manifest_item_id
),
active_projects as (
  select p.id
  from public.projects p
  where p.status = 'active'
),
project_counts as (
  select
    ei.effective_project_id as project_id,
    count(*)::int as manifest_item_count
  from effective_items ei
  group by ei.effective_project_id
),
project_gap_counts as (
  select
    count(*)::int as active_projects_total,
    count(*) filter (where coalesce(pc.manifest_item_count, 0) = 0)::int as active_projects_zero_coverage,
    count(*) filter (
      where coalesce(pc.manifest_item_count, 0) > 0
        and coalesce(pc.manifest_item_count, 0) < (:'underrep_threshold')::int
    )::int as active_projects_under_threshold
  from active_projects ap
  left join project_counts pc
    on pc.project_id = ap.id
),
failure_mode_counts as (
  select
    failure_mode_bucket,
    count(*)::int as manifest_item_count
  from effective_items
  group by failure_mode_bucket
),
failure_mode_gaps as (
  select
    count(*)::int as failure_mode_bucket_count,
    count(*) filter (where manifest_item_count < (:'underrep_threshold')::int)::int as underrepresented_failure_mode_buckets
  from failure_mode_counts
)
select
  now() at time zone 'utc' as generated_at_utc,
  :'manifest_name'::text as manifest_name,
  (select count(*)::int from effective_items) as manifest_item_total,
  pg.active_projects_total,
  pg.active_projects_zero_coverage,
  pg.active_projects_under_threshold,
  fg.failure_mode_bucket_count,
  fg.underrepresented_failure_mode_buckets,
  (:'underrep_threshold')::int as underrep_threshold
from project_gap_counts pg
cross join failure_mode_gaps fg;
