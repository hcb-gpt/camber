-- Canonical gate-readiness scorecard for financial claim receipts v1.
-- Additive/read-only layer for operator QA and pre-gate decisioning.

create or replace view public.v_financial_claim_v1_gate_readiness as
with receipts as (
  select
    count(*)::int as receipt_total,
    count(*) filter (where hit_count > 1)::int as replay_row_total,
    coalesce(sum(hit_count - 1) filter (where hit_count > 1), 0)::int as replay_hit_total,
    count(*) filter (where acceptance_level = 'proposed')::int as proposed_total,
    count(*) filter (where acceptance_level = 'review')::int as review_total,
    count(*) filter (where acceptance_level = 'accepted_planning')::int as accepted_planning_total,
    count(*) filter (where acceptance_level = 'accepted_execution')::int as accepted_execution_total,
    count(*) filter (where acceptance_level = 'rejected')::int as rejected_total,
    count(*) filter (where claim_type in ('invoice_link', 'commitment'))::int as high_risk_total
  from public.financial_claim_receipts_v1
),
queue as (
  select
    count(*)::int as queue_total,
    count(*) filter (where review_state in ('open', 'in_review'))::int as queue_open_total,
    count(*) filter (where review_state = 'resolved')::int as queue_resolved_total,
    count(*) filter (where review_state = 'rejected')::int as queue_rejected_total
  from public.financial_claim_review_queue_v1
),
high_risk_queue as (
  select
    count(*)::int as high_risk_open_queue_total
  from public.financial_claim_receipts_v1 r
  join public.financial_claim_review_queue_v1 q
    on q.dedupe_key = r.dedupe_key
  where r.claim_type in ('invoice_link', 'commitment')
    and q.review_state in ('open', 'in_review')
),
metrics as (
  select
    now() at time zone 'utc' as measured_at_utc,
    r.receipt_total,
    r.replay_row_total,
    r.replay_hit_total,
    r.proposed_total,
    r.review_total,
    r.accepted_planning_total,
    r.accepted_execution_total,
    r.rejected_total,
    r.high_risk_total,
    q.queue_total,
    q.queue_open_total,
    q.queue_resolved_total,
    q.queue_rejected_total,
    h.high_risk_open_queue_total,
    round(
      case
        when r.receipt_total = 0 then 100.0
        else (q.queue_open_total::numeric / r.receipt_total::numeric) * 100.0
      end,
      2
    ) as open_review_ratio_pct,
    round(
      case
        when r.receipt_total = 0 then 0.0
        else (r.replay_row_total::numeric / r.receipt_total::numeric) * 100.0
      end,
      2
    ) as replay_row_ratio_pct
  from receipts r
  cross join queue q
  cross join high_risk_queue h
),
score as (
  select
    m.*,
    greatest(
      0,
      least(
        100,
        100
        - case when m.receipt_total = 0 then 70 else 0 end
        - least(25, floor(m.open_review_ratio_pct / 4.0)::int)
        - least(20, m.high_risk_open_queue_total * 2)
        - least(10, m.rejected_total)
        - least(10, floor(m.replay_row_ratio_pct / 5.0)::int)
      )
    )::int as gate_score
  from metrics m
)
select
  measured_at_utc,
  receipt_total,
  replay_row_total,
  replay_hit_total,
  proposed_total,
  review_total,
  accepted_planning_total,
  accepted_execution_total,
  rejected_total,
  high_risk_total,
  queue_total,
  queue_open_total,
  queue_resolved_total,
  queue_rejected_total,
  high_risk_open_queue_total,
  open_review_ratio_pct,
  replay_row_ratio_pct,
  gate_score,
  case
    when receipt_total = 0 then 'HOLD'
    when high_risk_open_queue_total > 0 then 'HOLD'
    when open_review_ratio_pct > 20 then 'HOLD'
    when gate_score < 85 then 'HOLD'
    else 'GO'
  end as gate_status,
  array_remove(
    array[
      case when receipt_total = 0 then 'no_receipts' end,
      case when high_risk_open_queue_total > 0 then 'high_risk_open_reviews' end,
      case when open_review_ratio_pct > 20 then 'open_review_pressure' end,
      case when rejected_total > 0 then 'rejections_present' end
    ],
    null
  )::text[] as hold_reasons
from score;
comment on view public.v_financial_claim_v1_gate_readiness is
  'Canonical gate-readiness scorecard for financial claim receipts v1. Computes GO/HOLD status, gate score, and hold reasons from receipt + review queue state.';
