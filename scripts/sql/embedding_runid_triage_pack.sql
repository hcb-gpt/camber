-- embedding_runid_triage_pack.sql
-- Purpose: shared DATA+DEV probe pack for embedding staleness + run_id linkage issues.
-- Run:
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f scripts/sql/embedding_runid_triage_pack.sql

\echo '=== SECTION 1: Embedding backlog baseline ==='
with base as (
  select
    jc.id,
    jc.created_at,
    jc.run_id,
    jc.call_id,
    jc.project_id,
    jc.embedding,
    jr.claims_extracted,
    (jr.run_id is not null) as has_run
  from public.journal_claims jc
  left join public.journal_runs jr on jr.run_id = jc.run_id
)
select
  count(*) as total_claim_rows,
  count(*) filter (where embedding is null) as total_missing_embedding,
  count(*) filter (where embedding is null and created_at >= now() - interval '24 hours') as missing_embedding_24h,
  count(*) filter (where embedding is null and created_at >= now() - interval '7 days') as missing_embedding_7d,
  count(*) filter (where embedding is null and has_run = false) as missing_embedding_runid_unmatched,
  count(*) filter (where embedding is null and has_run = true and coalesce(claims_extracted,0)=0) as missing_embedding_run_claims_extracted_zero,
  count(*) filter (where embedding is null and has_run = true and coalesce(claims_extracted,0)>0) as missing_embedding_run_claims_extracted_positive
from base;

\echo '=== SECTION 2: run_id mismatch in journal_runs (claims_extracted>0 but no journal_claims) ==='
with runs_pos as (
  select run_id, call_id, project_id, started_at, completed_at, claims_extracted
  from public.journal_runs
  where coalesce(claims_extracted,0) > 0
), claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
), joined as (
  select r.*, coalesce(c.claim_rows,0) as claim_rows
  from runs_pos r
  left join claim_counts c on c.run_id=r.run_id
)
select
  count(*) filter (where started_at >= now()-interval '24 hours' and claim_rows=0) as runid_mismatch_24h,
  count(*) filter (where started_at >= now()-interval '7 days' and claim_rows=0) as runid_mismatch_7d,
  count(*) filter (where claim_rows=0) as runid_mismatch_all
from joined;

\echo '=== SECTION 3: Top 10 newest embedding backlog candidates ==='
select
  jc.id as claim_id,
  jc.created_at,
  jc.run_id,
  jc.call_id,
  jc.project_id
from public.journal_claims jc
where jc.embedding is null
order by jc.created_at desc
limit 10;

\echo '=== SECTION 4: Post-fix verification (run after embed writer fix) ==='
-- Expectation after fix:
-- - total_missing_embedding decreases
-- - missing_embedding_24h decreases first
-- - runid_mismatch_24h trends to 0 (or stable low baseline)
with s as (
  select
    count(*) filter (where embedding is null) as missing_embedding_all,
    count(*) filter (where embedding is null and created_at >= now() - interval '24 hours') as missing_embedding_24h,
    count(*) filter (where embedding is not null and created_at >= now() - interval '24 hours') as embedded_24h
  from public.journal_claims
)
select * from s;
