-- Financial receipts v1 ship-readiness composite view.
-- Combines gate-readiness score with canary-slice coverage checks.

create or replace view public.v_financial_receipts_v1_ship_readiness as
with gate as (
  select
    measured_at_utc,
    gate_status,
    gate_score,
    hold_reasons,
    receipt_total,
    queue_open_total,
    high_risk_open_queue_total,
    replay_row_total,
    replay_hit_total
  from public.v_financial_claim_v1_gate_readiness
),
canary_receipts as (
  select
    count(*)::int as canary_rows,
    count(distinct r.dedupe_key)::int as canary_distinct_keys,
    coalesce(sum(r.hit_count), 0)::int as canary_hit_count_sum,
    count(*) filter (
      where r.acceptance_level in ('accepted_planning', 'accepted_execution')
    )::int as canary_accepted_rows
  from public.financial_claim_receipts_v1 r
  where r.dedupe_key like 'frv1_canary_%'
),
canary_queue as (
  select
    count(*)::int as canary_queue_rows,
    count(*) filter (
      where exists (
        select 1
        from unnest(coalesce(q.reason_codes, '{}'::text[])) rc
        where rc = 'candidate_ambiguous'
      )
    )::int as canary_ambiguous_reason_rows,
    count(*) filter (
      where exists (
        select 1
        from unnest(coalesce(q.reason_codes, '{}'::text[])) rc
        where rc = 'high_risk_world_contact_missing'
      )
    )::int as canary_high_risk_reason_rows
  from public.financial_claim_review_queue_v1 q
  where q.dedupe_key like 'frv1_canary_%'
),
composed as (
  select
    g.measured_at_utc,
    g.gate_status,
    g.gate_score,
    g.hold_reasons,
    g.receipt_total,
    g.queue_open_total,
    g.high_risk_open_queue_total,
    g.replay_row_total,
    g.replay_hit_total,
    r.canary_rows,
    r.canary_distinct_keys,
    r.canary_hit_count_sum,
    r.canary_accepted_rows,
    q.canary_queue_rows,
    q.canary_ambiguous_reason_rows,
    q.canary_high_risk_reason_rows
  from gate g
  cross join canary_receipts r
  cross join canary_queue q
)
select
  c.measured_at_utc,
  c.gate_status,
  c.gate_score,
  c.hold_reasons,
  c.receipt_total,
  c.queue_open_total,
  c.high_risk_open_queue_total,
  c.replay_row_total,
  c.replay_hit_total,
  c.canary_rows,
  c.canary_distinct_keys,
  c.canary_hit_count_sum,
  c.canary_accepted_rows,
  c.canary_queue_rows,
  c.canary_ambiguous_reason_rows,
  c.canary_high_risk_reason_rows,
  case
    when c.gate_status = 'GO'
      and c.canary_distinct_keys >= 7
      and c.canary_accepted_rows = 0
      and c.canary_ambiguous_reason_rows >= 1
      and c.canary_high_risk_reason_rows >= 1
      then 'READY'
    else 'HOLD'
  end as ship_status,
  array_remove(
    array[
      case when c.gate_status <> 'GO' then 'gate_status_not_go' end,
      case when c.canary_distinct_keys < 7 then 'canary_keys_incomplete' end,
      case when c.canary_accepted_rows > 0 then 'canary_rows_unexpectedly_accepted' end,
      case when c.canary_ambiguous_reason_rows < 1 then 'missing_ambiguous_canary_queue_reason' end,
      case when c.canary_high_risk_reason_rows < 1 then 'missing_high_risk_gate_canary_queue_reason' end
    ],
    null
  )::text[] as ship_hold_reasons
from composed c;
comment on view public.v_financial_receipts_v1_ship_readiness is
  'Composite ship-readiness for financial receipts v1. Adds canary coverage/reason checks to gate-readiness GO/HOLD.';
