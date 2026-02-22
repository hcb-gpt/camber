-- R1 silent-zero investigation + guard proof pack.
-- Purpose:
-- - Classify "claims_extracted > 0 and promotions == 0" runs by run_id/source_run_id mapping.
-- - Separate true silent-zero failures from consolidation mapping artifacts.
-- - Provide run-level diagnostics for triage and completion receipts.
--
-- Run:
--   scripts/query.sh --file scripts/sql/r1_zero_promotion_runid_guard_check.sql

with recent_success as (
  select
    jr.run_id,
    jr.call_id,
    jr.started_at,
    coalesce(jr.config->>'mode','(null)') as mode,
    nullif(jr.config->>'source_run_id','')::uuid as source_run_id,
    coalesce(jr.claims_extracted,0) as claims_extracted
  from public.journal_runs jr
  where jr.status = 'success'
    and coalesce(jr.claims_extracted,0) > 0
    and jr.started_at >= now() - interval '24 hours'
),
claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
),
promote_counts as (
  select run_id, count(*)::int as promotion_rows
  from public.promotion_log
  group by run_id
),
belief_counts as (
  select source_run_id as run_id, count(*)::int as belief_rows
  from public.belief_claims
  where source_run_id is not null
  group by source_run_id
),
review_counts as (
  select run_id, count(*)::int as review_rows
  from public.journal_review_queue
  where item_type = 'claim'
  group by run_id
),
base as (
  select
    rs.*,
    coalesce(cc.claim_rows,0) as claim_rows,
    coalesce(pc.promotion_rows,0) as promotion_rows,
    coalesce(bc.belief_rows,0) as belief_rows,
    coalesce(rc.review_rows,0) as review_rows,
    coalesce(ccs.claim_rows,0) as source_claim_rows,
    coalesce(pcs.promotion_rows,0) as source_promotion_rows,
    coalesce(bcs.belief_rows,0) as source_belief_rows,
    coalesce(rcs.review_rows,0) as source_review_rows
  from recent_success rs
  left join claim_counts cc on cc.run_id = rs.run_id
  left join promote_counts pc on pc.run_id = rs.run_id
  left join belief_counts bc on bc.run_id = rs.run_id
  left join review_counts rc on rc.run_id = rs.run_id
  left join claim_counts ccs on ccs.run_id = rs.source_run_id
  left join promote_counts pcs on pcs.run_id = rs.source_run_id
  left join belief_counts bcs on bcs.run_id = rs.source_run_id
  left join review_counts rcs on rcs.run_id = rs.source_run_id
),
classified as (
  select
    b.*,
    case
      when b.promotion_rows > 0 or b.belief_rows > 0 then 'promoted_on_run_id'
      when b.source_run_id is not null and (b.source_promotion_rows > 0 or b.source_belief_rows > 0)
        then 'promoted_on_source_run_id'
      when b.claim_rows = 0 and b.source_run_id is not null and b.source_claim_rows > 0
        then 'claims_persisted_on_source_run_id'
      when b.claim_rows > 0 and b.review_rows > 0
        then 'review_routed_zero_promote'
      when b.claim_rows > 0 and b.review_rows = 0
        then 'true_silent_zero_candidate'
      else 'other_zero_case'
    end as classification
  from base b
)
select
  classification,
  count(*)::int as runs,
  count(distinct call_id)::int as calls
from classified
group by classification
order by runs desc, classification;

with recent_success as (
  select
    jr.run_id,
    jr.call_id,
    jr.started_at,
    coalesce(jr.config->>'mode','(null)') as mode,
    nullif(jr.config->>'source_run_id','')::uuid as source_run_id,
    coalesce(jr.claims_extracted,0) as claims_extracted
  from public.journal_runs jr
  where jr.status = 'success'
    and coalesce(jr.claims_extracted,0) > 0
    and jr.started_at >= now() - interval '24 hours'
),
claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
),
promote_counts as (
  select run_id, count(*)::int as promotion_rows
  from public.promotion_log
  group by run_id
),
belief_counts as (
  select source_run_id as run_id, count(*)::int as belief_rows
  from public.belief_claims
  where source_run_id is not null
  group by source_run_id
),
review_counts as (
  select run_id, count(*)::int as review_rows
  from public.journal_review_queue
  where item_type = 'claim'
  group by run_id
),
base as (
  select
    rs.*,
    coalesce(cc.claim_rows,0) as claim_rows,
    coalesce(pc.promotion_rows,0) as promotion_rows,
    coalesce(bc.belief_rows,0) as belief_rows,
    coalesce(rc.review_rows,0) as review_rows,
    coalesce(ccs.claim_rows,0) as source_claim_rows,
    coalesce(pcs.promotion_rows,0) as source_promotion_rows,
    coalesce(bcs.belief_rows,0) as source_belief_rows,
    coalesce(rcs.review_rows,0) as source_review_rows
  from recent_success rs
  left join claim_counts cc on cc.run_id = rs.run_id
  left join promote_counts pc on pc.run_id = rs.run_id
  left join belief_counts bc on bc.run_id = rs.run_id
  left join review_counts rc on rc.run_id = rs.run_id
  left join claim_counts ccs on ccs.run_id = rs.source_run_id
  left join promote_counts pcs on pcs.run_id = rs.source_run_id
  left join belief_counts bcs on bcs.run_id = rs.source_run_id
  left join review_counts rcs on rcs.run_id = rs.source_run_id
),
classified as (
  select
    b.*,
    case
      when b.promotion_rows > 0 or b.belief_rows > 0 then 'promoted_on_run_id'
      when b.source_run_id is not null and (b.source_promotion_rows > 0 or b.source_belief_rows > 0)
        then 'promoted_on_source_run_id'
      when b.claim_rows = 0 and b.source_run_id is not null and b.source_claim_rows > 0
        then 'claims_persisted_on_source_run_id'
      when b.claim_rows > 0 and b.review_rows > 0
        then 'review_routed_zero_promote'
      when b.claim_rows > 0 and b.review_rows = 0
        then 'true_silent_zero_candidate'
      else 'other_zero_case'
    end as classification
  from base b
)
select
  now() at time zone 'utc' as measured_at_utc,
  count(*) filter (where classification = 'true_silent_zero_candidate')::int as true_silent_zero_runs_24h,
  count(distinct call_id) filter (where classification = 'true_silent_zero_candidate')::int as true_silent_zero_calls_24h,
  case
    when count(*) filter (where classification = 'true_silent_zero_candidate') > 0 then 'FAIL'
    else 'PASS'
  end as no_silent_zero_guard,
  count(*) filter (where classification = 'claims_persisted_on_source_run_id')::int as source_mapping_runs_24h,
  count(*) filter (where classification = 'promoted_on_source_run_id')::int as source_promoted_runs_24h
from classified;

with recent_success as (
  select
    jr.run_id,
    jr.call_id,
    jr.started_at,
    coalesce(jr.config->>'mode','(null)') as mode,
    nullif(jr.config->>'source_run_id','')::uuid as source_run_id,
    coalesce(jr.claims_extracted,0) as claims_extracted
  from public.journal_runs jr
  where jr.status = 'success'
    and coalesce(jr.claims_extracted,0) > 0
    and jr.started_at >= now() - interval '24 hours'
),
claim_counts as (
  select run_id, count(*)::int as claim_rows
  from public.journal_claims
  group by run_id
),
promote_counts as (
  select run_id, count(*)::int as promotion_rows
  from public.promotion_log
  group by run_id
),
belief_counts as (
  select source_run_id as run_id, count(*)::int as belief_rows
  from public.belief_claims
  where source_run_id is not null
  group by source_run_id
),
review_counts as (
  select run_id, count(*)::int as review_rows
  from public.journal_review_queue
  where item_type = 'claim'
  group by run_id
),
base as (
  select
    rs.*,
    coalesce(cc.claim_rows,0) as claim_rows,
    coalesce(pc.promotion_rows,0) as promotion_rows,
    coalesce(bc.belief_rows,0) as belief_rows,
    coalesce(rc.review_rows,0) as review_rows,
    coalesce(ccs.claim_rows,0) as source_claim_rows,
    coalesce(pcs.promotion_rows,0) as source_promotion_rows,
    coalesce(bcs.belief_rows,0) as source_belief_rows
  from recent_success rs
  left join claim_counts cc on cc.run_id = rs.run_id
  left join promote_counts pc on pc.run_id = rs.run_id
  left join belief_counts bc on bc.run_id = rs.run_id
  left join review_counts rc on rc.run_id = rs.run_id
  left join claim_counts ccs on ccs.run_id = rs.source_run_id
  left join promote_counts pcs on pcs.run_id = rs.source_run_id
  left join belief_counts bcs on bcs.run_id = rs.source_run_id
),
classified as (
  select
    b.*,
    case
      when b.promotion_rows > 0 or b.belief_rows > 0 then 'promoted_on_run_id'
      when b.source_run_id is not null and (b.source_promotion_rows > 0 or b.source_belief_rows > 0)
        then 'promoted_on_source_run_id'
      when b.claim_rows = 0 and b.source_run_id is not null and b.source_claim_rows > 0
        then 'claims_persisted_on_source_run_id'
      when b.claim_rows > 0 and b.review_rows > 0
        then 'review_routed_zero_promote'
      when b.claim_rows > 0 and b.review_rows = 0
        then 'true_silent_zero_candidate'
      else 'other_zero_case'
    end as classification
  from base b
)
select
  run_id,
  call_id,
  mode,
  started_at,
  claims_extracted,
  claim_rows,
  promotion_rows,
  belief_rows,
  review_rows,
  source_run_id,
  source_claim_rows,
  source_promotion_rows,
  source_belief_rows,
  classification
from classified
where classification in (
  'true_silent_zero_candidate',
  'claims_persisted_on_source_run_id',
  'promoted_on_source_run_id',
  'other_zero_case'
)
order by started_at desc, run_id
limit 200;
