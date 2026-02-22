-- embedding_freshness_pair_support_pack.sql
-- Purpose: copy/paste evidence pack for embedding freshness checks.
--
-- Run:
--   scripts/query.sh --file scripts/sql/embedding_freshness_pair_support_pack.sql
--
-- Gate thresholds:
--   1) missing_embedding_24h <= 0
--   2) latest_actionable_calls_24h <= 0
--   3) if claims_24h > 0 then embedded_24h > 0

\echo '=== EMBED / 1) Freshness snapshot (24h) ==='
with base as (
  select
    count(*) filter (where jc.created_at >= now() - interval '24 hours')::bigint as claims_24h,
    count(*) filter (where jc.embedding is null)::bigint as missing_embedding_all,
    count(*) filter (where jc.embedding is null and jc.created_at >= now() - interval '24 hours')::bigint as missing_embedding_24h,
    count(*) filter (where jc.embedding is not null and jc.created_at >= now() - interval '24 hours')::bigint as embedded_24h
  from public.journal_claims jc
)
select
  to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as ts_utc,
  claims_24h,
  missing_embedding_all,
  missing_embedding_24h,
  embedded_24h
from base;

\echo '=== EMBED / 2) Reliability sidecar (24h) ==='
with runs as (
  select
    run_id,
    call_id,
    started_at,
    status,
    coalesce(config->>'mode','(null)') as mode,
    coalesce(claims_extracted,0) as claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
    and started_at >= now() - interval '24 hours'
    and call_id !~ '^cll_lineage_test_'
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), joined as (
  select
    r.*,
    coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
), ranked as (
  select
    j.*,
    row_number() over (partition by j.call_id order by j.started_at desc) as rn
  from joined j
)
select
  count(*) filter (where claim_rows = 0)::bigint as runid_mismatch_24h,
  count(*) filter (where rn = 1 and claim_rows = 0 and not (mode='consolidate' and status='success'))::bigint as latest_actionable_calls_24h
from ranked;

\echo '=== EMBED / 3) Gate decision helper ==='
with base as (
  select
    count(*) filter (where jc.created_at >= now() - interval '24 hours')::bigint as claims_24h,
    count(*) filter (where jc.embedding is null and jc.created_at >= now() - interval '24 hours')::bigint as missing_embedding_24h,
    count(*) filter (where jc.embedding is not null and jc.created_at >= now() - interval '24 hours')::bigint as embedded_24h
  from public.journal_claims jc
), runs as (
  select
    run_id,
    call_id,
    started_at,
    status,
    coalesce(config->>'mode','(null)') as mode,
    coalesce(claims_extracted,0) as claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
    and started_at >= now() - interval '24 hours'
    and call_id !~ '^cll_lineage_test_'
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), ranked as (
  select
    r.call_id,
    r.mode,
    r.status,
    coalesce(c.claim_rows,0) as claim_rows,
    row_number() over (partition by r.call_id order by r.started_at desc) as rn
  from runs r
  left join claim_counts c on c.run_id = r.run_id
), gate as (
  select
    count(*) filter (where rn = 1 and claim_rows = 0 and not (mode='consolidate' and status='success'))::bigint as latest_actionable_calls_24h
  from ranked
)
select
  to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as ts_utc,
  base.claims_24h,
  base.missing_embedding_24h,
  base.embedded_24h,
  gate.latest_actionable_calls_24h,
  case
    when base.missing_embedding_24h > 0 then 'NO_GO'
    when gate.latest_actionable_calls_24h > 0 then 'NO_GO'
    when base.claims_24h > 0 and base.embedded_24h = 0 then 'NO_GO'
    else 'GO'
  end as go_no_go,
  case
    when base.missing_embedding_24h > 0 then 'missing_embedding_24h>0'
    when gate.latest_actionable_calls_24h > 0 then 'latest_actionable_calls_24h>0'
    when base.claims_24h > 0 and base.embedded_24h = 0 then 'claims_24h>0_and_embedded_24h=0'
    else 'within_thresholds'
  end as reason
from base, gate;
