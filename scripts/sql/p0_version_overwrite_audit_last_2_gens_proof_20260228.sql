-- Proof pack: P0 version-overwrite audit (last 7 days + last 2 deploy generations)
-- Receipt: dispatch__p0_version_overwrite_audit_last_2_gens_takeover__data1__20260228
-- Usage:
--   /usr/local/opt/libpq/bin/psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
--     -f scripts/sql/p0_version_overwrite_audit_last_2_gens_proof_20260228.sql

\echo 'Q0) Last 2 accepted deploy generations per function (edge_deploy_receipts)'
with ranked as (
  select
    edr.function_slug,
    edr.git_sha,
    edr.deployed_at,
    edr.previous_git_sha,
    edr.git_commit_ts,
    row_number() over (partition by edr.function_slug order by edr.deployed_at desc) as rn
  from public.edge_deploy_receipts edr
  where edr.accepted is true
)
select
  function_slug,
  rn as generation_rank,
  deployed_at,
  git_sha,
  previous_git_sha,
  git_commit_ts
from ranked
where rn <= 2
order by function_slug, generation_rank;

\echo 'Q1) interaction_id with >1 distinct run_id in last 7 days (minimum required proof class #1)'
with run_events as (
  select
    'evidence_events'::text as source_table,
    ev.source_id as interaction_id,
    ev.source_run_id as run_id,
    ev.created_at as observed_at
  from public.evidence_events ev
  where ev.created_at >= now() - interval '7 days'
    and coalesce(ev.source_id, '') <> ''
    and coalesce(ev.source_run_id, '') <> ''

  union all

  select
    'journal_claims'::text as source_table,
    jc.call_id as interaction_id,
    jc.run_id::text as run_id,
    jc.created_at as observed_at
  from public.journal_claims jc
  where jc.created_at >= now() - interval '7 days'
    and coalesce(jc.call_id, '') <> ''

  union all

  select
    'journal_open_loops'::text as source_table,
    jol.call_id as interaction_id,
    jol.run_id::text as run_id,
    jol.created_at as observed_at
  from public.journal_open_loops jol
  where jol.created_at >= now() - interval '7 days'
    and coalesce(jol.call_id, '') <> ''
), grouped as (
  select
    re.interaction_id,
    count(distinct re.run_id) as distinct_run_ids,
    count(*) as run_rows,
    min(re.observed_at) as first_seen,
    max(re.observed_at) as last_seen,
    array_agg(distinct re.source_table order by re.source_table) as source_tables,
    array_agg(distinct re.run_id order by re.run_id) as run_ids
  from run_events re
  group by re.interaction_id
  having count(distinct re.run_id) > 1
)
select
  count(*)::int as interaction_ids_with_multi_run_id,
  coalesce(sum(run_rows), 0)::int as contributing_rows
from grouped;

with run_events as (
  select
    'evidence_events'::text as source_table,
    ev.source_id as interaction_id,
    ev.source_run_id as run_id,
    ev.created_at as observed_at
  from public.evidence_events ev
  where ev.created_at >= now() - interval '7 days'
    and coalesce(ev.source_id, '') <> ''
    and coalesce(ev.source_run_id, '') <> ''

  union all

  select
    'journal_claims'::text as source_table,
    jc.call_id as interaction_id,
    jc.run_id::text as run_id,
    jc.created_at as observed_at
  from public.journal_claims jc
  where jc.created_at >= now() - interval '7 days'
    and coalesce(jc.call_id, '') <> ''

  union all

  select
    'journal_open_loops'::text as source_table,
    jol.call_id as interaction_id,
    jol.run_id::text as run_id,
    jol.created_at as observed_at
  from public.journal_open_loops jol
  where jol.created_at >= now() - interval '7 days'
    and coalesce(jol.call_id, '') <> ''
), grouped as (
  select
    re.interaction_id,
    count(distinct re.run_id) as distinct_run_ids,
    count(*) as run_rows,
    min(re.observed_at) as first_seen,
    max(re.observed_at) as last_seen,
    array_agg(distinct re.source_table order by re.source_table) as source_tables,
    array_agg(distinct re.run_id order by re.run_id) as run_ids
  from run_events re
  group by re.interaction_id
  having count(distinct re.run_id) > 1
)
select
  interaction_id,
  distinct_run_ids,
  run_rows,
  first_seen,
  last_seen,
  source_tables,
  run_ids
from grouped
order by distinct_run_ids desc, run_rows desc, last_seen desc
limit 20;

\echo 'Q2) Rows updated multiple times within 1h (minimum required proof class #2)'
with row_events as (
  select
    'calls_raw'::text as source_table,
    cr.interaction_id as logical_key,
    coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) as observed_at,
    cr.id::text as row_pointer
  from public.calls_raw cr
  where coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) >= now() - interval '7 days'
    and coalesce(cr.interaction_id, '') <> ''

  union all

  select
    'interactions'::text as source_table,
    i.interaction_id as logical_key,
    coalesce(i.ingested_at_utc, i.event_at_utc) as observed_at,
    i.id::text as row_pointer
  from public.interactions i
  where coalesce(i.ingested_at_utc, i.event_at_utc) >= now() - interval '7 days'
    and coalesce(i.interaction_id, '') <> ''

  union all

  select
    'event_audit'::text as source_table,
    ea.interaction_id as logical_key,
    ea.received_at_utc as observed_at,
    ea.id::text as row_pointer
  from public.event_audit ea
  where ea.received_at_utc >= now() - interval '7 days'
    and coalesce(ea.interaction_id, '') <> ''
), grouped as (
  select
    re.source_table,
    re.logical_key,
    count(*) as row_count,
    min(re.observed_at) as first_seen,
    max(re.observed_at) as last_seen,
    extract(epoch from (max(re.observed_at) - min(re.observed_at))) / 60.0 as span_minutes,
    array_agg(re.row_pointer order by re.observed_at desc) as row_pointers
  from row_events re
  group by re.source_table, re.logical_key
  having count(*) > 1
     and max(re.observed_at) - min(re.observed_at) <= interval '1 hour'
)
select
  count(*)::int as multi_write_keys_within_1h,
  coalesce(sum(row_count), 0)::int as contributing_rows
from grouped;

with row_events as (
  select
    'calls_raw'::text as source_table,
    cr.interaction_id as logical_key,
    coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) as observed_at,
    cr.id::text as row_pointer
  from public.calls_raw cr
  where coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) >= now() - interval '7 days'
    and coalesce(cr.interaction_id, '') <> ''

  union all

  select
    'interactions'::text as source_table,
    i.interaction_id as logical_key,
    coalesce(i.ingested_at_utc, i.event_at_utc) as observed_at,
    i.id::text as row_pointer
  from public.interactions i
  where coalesce(i.ingested_at_utc, i.event_at_utc) >= now() - interval '7 days'
    and coalesce(i.interaction_id, '') <> ''

  union all

  select
    'event_audit'::text as source_table,
    ea.interaction_id as logical_key,
    ea.received_at_utc as observed_at,
    ea.id::text as row_pointer
  from public.event_audit ea
  where ea.received_at_utc >= now() - interval '7 days'
    and coalesce(ea.interaction_id, '') <> ''
), grouped as (
  select
    re.source_table,
    re.logical_key,
    count(*) as row_count,
    min(re.observed_at) as first_seen,
    max(re.observed_at) as last_seen,
    round((extract(epoch from (max(re.observed_at) - min(re.observed_at))) / 60.0)::numeric, 2) as span_minutes,
    (array_agg(re.row_pointer order by re.observed_at desc))[1:5] as sample_row_pointers
  from row_events re
  group by re.source_table, re.logical_key
  having count(*) > 1
     and max(re.observed_at) - min(re.observed_at) <= interval '1 hour'
)
select
  source_table,
  logical_key as interaction_id,
  row_count,
  first_seen,
  last_seen,
  span_minutes,
  sample_row_pointers
from grouped
order by row_count desc, last_seen desc
limit 20;

\echo 'Q3) Accepted deploy-generation regressions (minimum required proof class #3A)'
with accepted as (
  select
    edr.function_slug,
    edr.git_sha,
    edr.deployed_at,
    edr.git_commit_ts,
    lag(edr.git_commit_ts) over (partition by edr.function_slug order by edr.deployed_at) as prev_git_commit_ts,
    lag(edr.git_sha) over (partition by edr.function_slug order by edr.deployed_at) as prev_git_sha
  from public.edge_deploy_receipts edr
  where edr.accepted is true
), regressions as (
  select
    a.function_slug,
    a.deployed_at,
    a.git_sha,
    a.git_commit_ts,
    a.prev_git_sha,
    a.prev_git_commit_ts
  from accepted a
  where a.prev_git_commit_ts is not null
    and a.git_commit_ts < a.prev_git_commit_ts
)
select
  count(*)::int as accepted_deploy_regressions
from regressions;

with accepted as (
  select
    edr.function_slug,
    edr.git_sha,
    edr.deployed_at,
    edr.git_commit_ts,
    lag(edr.git_commit_ts) over (partition by edr.function_slug order by edr.deployed_at) as prev_git_commit_ts,
    lag(edr.git_sha) over (partition by edr.function_slug order by edr.deployed_at) as prev_git_sha
  from public.edge_deploy_receipts edr
  where edr.accepted is true
), regressions as (
  select
    a.function_slug,
    a.deployed_at,
    a.git_sha,
    a.git_commit_ts,
    a.prev_git_sha,
    a.prev_git_commit_ts
  from accepted a
  where a.prev_git_commit_ts is not null
    and a.git_commit_ts < a.prev_git_commit_ts
)
select
  function_slug,
  deployed_at,
  git_sha,
  git_commit_ts,
  prev_git_sha,
  prev_git_commit_ts
from regressions
order by deployed_at desc
limit 20;

\echo 'Q4) Runtime pipeline_version regressions by interaction_id in last 7 days (minimum required proof class #3B)'
with events as (
  select
    'event_audit'::text as source_table,
    ea.interaction_id,
    ea.received_at_utc as observed_at,
    ea.pipeline_version as version_text
  from public.event_audit ea
  where ea.received_at_utc >= now() - interval '7 days'
    and coalesce(ea.interaction_id, '') <> ''
    and coalesce(ea.pipeline_version, '') <> ''

  union all

  select
    'calls_raw'::text as source_table,
    cr.interaction_id,
    coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) as observed_at,
    cr.pipeline_version as version_text
  from public.calls_raw cr
  where coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) >= now() - interval '7 days'
    and coalesce(cr.interaction_id, '') <> ''
    and coalesce(cr.pipeline_version, '') <> ''
), parsed as (
  select
    e.source_table,
    e.interaction_id,
    e.observed_at,
    e.version_text,
    coalesce(nullif(regexp_replace(split_part(regexp_replace(e.version_text, '[^0-9\\.]', '', 'g'), '.', 1), '[^0-9]', '', 'g'), ''), '0')::int as major,
    coalesce(nullif(regexp_replace(split_part(regexp_replace(e.version_text, '[^0-9\\.]', '', 'g'), '.', 2), '[^0-9]', '', 'g'), ''), '0')::int as minor,
    coalesce(nullif(regexp_replace(split_part(regexp_replace(e.version_text, '[^0-9\\.]', '', 'g'), '.', 3), '[^0-9]', '', 'g'), ''), '0')::int as patch
  from events e
), ordered as (
  select
    p.source_table,
    p.interaction_id,
    p.observed_at,
    p.version_text,
    p.major,
    p.minor,
    p.patch,
    lag(p.version_text) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_version_text,
    lag(p.major) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_major,
    lag(p.minor) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_minor,
    lag(p.patch) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_patch
  from parsed p
), regressions as (
  select
    o.source_table,
    o.interaction_id,
    o.observed_at,
    o.prev_version_text,
    o.version_text,
    o.prev_major,
    o.prev_minor,
    o.prev_patch,
    o.major,
    o.minor,
    o.patch
  from ordered o
  where o.prev_version_text is not null
    and (o.major, o.minor, o.patch) < (o.prev_major, o.prev_minor, o.prev_patch)
)
select
  count(*)::int as runtime_pipeline_version_regression_events,
  count(distinct interaction_id)::int as impacted_interaction_ids
from regressions;

with events as (
  select
    'event_audit'::text as source_table,
    ea.interaction_id,
    ea.received_at_utc as observed_at,
    ea.pipeline_version as version_text
  from public.event_audit ea
  where ea.received_at_utc >= now() - interval '7 days'
    and coalesce(ea.interaction_id, '') <> ''
    and coalesce(ea.pipeline_version, '') <> ''

  union all

  select
    'calls_raw'::text as source_table,
    cr.interaction_id,
    coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) as observed_at,
    cr.pipeline_version as version_text
  from public.calls_raw cr
  where coalesce(cr.received_at_utc, cr.ingested_at_utc, cr.event_at_utc) >= now() - interval '7 days'
    and coalesce(cr.interaction_id, '') <> ''
    and coalesce(cr.pipeline_version, '') <> ''
), parsed as (
  select
    e.source_table,
    e.interaction_id,
    e.observed_at,
    e.version_text,
    coalesce(nullif(regexp_replace(split_part(regexp_replace(e.version_text, '[^0-9\\.]', '', 'g'), '.', 1), '[^0-9]', '', 'g'), ''), '0')::int as major,
    coalesce(nullif(regexp_replace(split_part(regexp_replace(e.version_text, '[^0-9\\.]', '', 'g'), '.', 2), '[^0-9]', '', 'g'), ''), '0')::int as minor,
    coalesce(nullif(regexp_replace(split_part(regexp_replace(e.version_text, '[^0-9\\.]', '', 'g'), '.', 3), '[^0-9]', '', 'g'), ''), '0')::int as patch
  from events e
), ordered as (
  select
    p.source_table,
    p.interaction_id,
    p.observed_at,
    p.version_text,
    p.major,
    p.minor,
    p.patch,
    lag(p.version_text) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_version_text,
    lag(p.major) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_major,
    lag(p.minor) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_minor,
    lag(p.patch) over (partition by p.source_table, p.interaction_id order by p.observed_at) as prev_patch
  from parsed p
), regressions as (
  select
    o.source_table,
    o.interaction_id,
    o.observed_at,
    o.prev_version_text,
    o.version_text
  from ordered o
  where o.prev_version_text is not null
    and (o.major, o.minor, o.patch) < (o.prev_major, o.prev_minor, o.prev_patch)
)
select
  source_table,
  interaction_id,
  observed_at,
  prev_version_text,
  version_text
from regressions
order by observed_at desc
limit 20;
