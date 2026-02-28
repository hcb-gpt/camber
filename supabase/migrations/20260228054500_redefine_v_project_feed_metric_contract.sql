-- Redefine v_project_feed metric contract with explicit total vs 7d fields.
-- Keeps legacy columns for backward compatibility.

create or replace view public.v_project_feed as
with interactions_rollup as (
  select
    i.project_id,
    count(*) as total_interactions,
    max(i.event_at_utc) as last_interaction_at,
    count(*) filter (
      where i.event_at_utc >= now() - interval '7 days'
    ) as interactions_7d
  from public.interactions i
  where i.project_id is not null
  group by i.project_id
),
claims_rollup as (
  select
    jc.project_id,
    count(*) filter (where jc.active = true) as active_journal_claims_total,
    count(*) filter (
      where jc.active = true
        and jc.created_at >= now() - interval '7 days'
    ) as active_journal_claims_7d
  from public.journal_claims jc
  where jc.project_id is not null
  group by jc.project_id
),
loops_rollup as (
  select
    jol.project_id,
    count(*) filter (where jol.status = 'open') as open_loops_total,
    count(*) filter (
      where jol.status = 'open'
        and jol.created_at >= now() - interval '7 days'
    ) as open_loops_7d
  from public.journal_open_loops jol
  where jol.project_id is not null
  group by jol.project_id
),
belief_rollup as (
  select
    bc.project_id,
    count(*) as promoted_claims,
    max(bc.event_at_utc) as last_promoted_at
  from public.belief_claims bc
  where bc.project_id is not null
  group by bc.project_id
),
striking_rollup as (
  select
    sa.applied_project_id as project_id,
    count(*) as striking_signal_count,
    max(ss.created_at) as last_striking_at,
    count(*) filter (
      where ss.created_at >= now() - interval '7 days'
    ) as striking_signal_count_7d
  from public.striking_signals ss
  join public.conversation_spans cs
    on cs.id = ss.span_id
  join public.span_attributions sa
    on sa.span_id = cs.id
  where sa.applied_project_id is not null
  group by sa.applied_project_id
),
span_review_rollup as (
  select
    i.project_id,
    count(*) filter (where sa.needs_review = true) as pending_reviews_span_total
  from public.interactions i
  join public.conversation_spans cs
    on cs.interaction_id = i.interaction_id
  join public.span_attributions sa
    on sa.span_id = cs.id
  where i.project_id is not null
  group by i.project_id
),
queue_review_rollup as (
  select
    i.project_id,
    count(*) filter (where rq.status = 'pending') as pending_reviews_queue_total,
    count(*) filter (
      where rq.status = 'pending'
        and rq.created_at >= now() - interval '7 days'
    ) as pending_reviews_queue_7d
  from public.interactions i
  join public.review_queue rq
    on rq.interaction_id = i.interaction_id
  where i.project_id is not null
  group by i.project_id
)
select
  p.id as project_id,
  p.name as project_name,
  p.status as project_status,
  p.phase,
  p.client_name,
  coalesce(ir.total_interactions, 0) as total_interactions,
  ir.last_interaction_at,
  coalesce(ir.interactions_7d, 0) as interactions_7d,
  -- Legacy columns preserved with explicit total semantics.
  coalesce(cr.active_journal_claims_total, 0) as active_journal_claims,
  coalesce(lr.open_loops_total, 0) as open_loops,
  coalesce(br.promoted_claims, 0) as promoted_claims,
  br.last_promoted_at,
  coalesce(sr.striking_signal_count, 0) as striking_signal_count,
  sr.last_striking_at,
  -- Legacy column preserved: span-attribution review queue precursor.
  coalesce(srr.pending_reviews_span_total, 0) as pending_reviews,
  case
    when coalesce(lr.open_loops_total, 0) >= 5 then 'high_open_loops'
    when coalesce(sr.striking_signal_count_7d, 0) >= 3 then 'elevated_striking'
    when ir.last_interaction_at < now() - interval '14 days' then 'stale_project'
    else 'normal'
  end as risk_flag,
  -- New explicit contract fields.
  coalesce(cr.active_journal_claims_total, 0) as active_journal_claims_total,
  coalesce(cr.active_journal_claims_7d, 0) as active_journal_claims_7d,
  coalesce(lr.open_loops_total, 0) as open_loops_total,
  coalesce(lr.open_loops_7d, 0) as open_loops_7d,
  coalesce(srr.pending_reviews_span_total, 0) as pending_reviews_span_total,
  coalesce(qrr.pending_reviews_queue_total, 0) as pending_reviews_queue_total,
  coalesce(qrr.pending_reviews_queue_7d, 0) as pending_reviews_queue_7d
from public.projects p
left join interactions_rollup ir
  on ir.project_id = p.id
left join claims_rollup cr
  on cr.project_id = p.id
left join loops_rollup lr
  on lr.project_id = p.id
left join belief_rollup br
  on br.project_id = p.id
left join striking_rollup sr
  on sr.project_id = p.id
left join span_review_rollup srr
  on srr.project_id = p.id
left join queue_review_rollup qrr
  on qrr.project_id = p.id
order by ir.last_interaction_at desc nulls last;

comment on view public.v_project_feed is
'Project feed with explicit metric contract: legacy totals + explicit *_total and *_7d fields for claims/loops/reviews.';

