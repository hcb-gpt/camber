-- runid_mismatch_reduction_gift_pack.sql
-- Purpose: reusable, copy-paste SQL kit for DATA/DEV reliability follow-through.
-- Run:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f scripts/sql/runid_mismatch_reduction_gift_pack.sql

\echo '=== 1) Legacy mismatch baseline (24h/all) ==='
with runs as (
  select run_id, call_id, started_at, status, coalesce(config->>'mode','(null)') as mode, claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), mism as (
  select r.*, coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
  where coalesce(c.claim_rows,0) = 0
)
select
  count(*) filter (where started_at >= now()-interval '24 hours') as legacy_mismatch_24h,
  count(*) as legacy_mismatch_all
from mism;

\echo '=== 2) Source segmentation (24h) ==='
with runs as (
  select run_id, call_id, started_at, status, coalesce(config->>'mode','(null)') as mode, claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), mism as (
  select r.*, coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
  where coalesce(c.claim_rows,0) = 0
    and r.started_at >= now()-interval '24 hours'
)
select
  mode,
  status,
  count(*) as mismatch_runs,
  count(distinct call_id) as mismatch_calls
from mism
group by mode, status
order by mismatch_runs desc, mode, status;

\echo '=== 3) Top repeated call contributors (24h) ==='
with runs as (
  select run_id, call_id, started_at, status, coalesce(config->>'mode','(null)') as mode, claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), mism as (
  select r.*, coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
  where coalesce(c.claim_rows,0) = 0
    and r.started_at >= now()-interval '24 hours'
)
select
  call_id,
  mode,
  status,
  count(*) as mismatch_runs,
  min(started_at) as first_seen_utc,
  max(started_at) as last_seen_utc
from mism
group by call_id, mode, status
order by mismatch_runs desc, last_seen_utc desc
limit 10;

\echo '=== 4) Actionable mismatch metric (24h) ==='
-- Reduces false positives from consolidate-success retry churn by:
-- 1) excluding consolidate/success runs
-- 2) deduping to one unit per call_id.
with runs as (
  select run_id, call_id, started_at, status, coalesce(config->>'mode','(null)') as mode, claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), mism as (
  select r.*, coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
  where coalesce(c.claim_rows,0) = 0
    and r.started_at >= now()-interval '24 hours'
), actionable as (
  select *
  from mism
  where not (mode = 'consolidate' and status = 'success')
)
select
  count(*) as actionable_mismatch_runs_24h,
  count(distinct call_id) as actionable_mismatch_calls_24h
from actionable;

\echo '=== 5) Threshold decision helper ==='
with runs as (
  select run_id, call_id, started_at, status, coalesce(config->>'mode','(null)') as mode, claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), mism as (
  select r.*, coalesce(c.claim_rows,0) as claim_rows
  from runs r
  left join claim_counts c on c.run_id = r.run_id
  where coalesce(c.claim_rows,0) = 0
    and r.started_at >= now()-interval '24 hours'
), actionable as (
  select count(distinct call_id) as calls_24h
  from mism
  where not (mode = 'consolidate' and status = 'success')
)
select
  calls_24h as actionable_mismatch_calls_24h,
  case
    when calls_24h = 0 then 'GREEN'
    when calls_24h <= 3 then 'YELLOW'
    else 'RED'
  end as alert_band
from actionable;
