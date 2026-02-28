-- Root-cause buckets for hard_drop pending spans + journal stale breakdown.

with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    coalesce(cs.created_at, now()) as span_created_at_utc
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
    and cs.interaction_id not like 'cll_SHADOW%'
    and cs.interaction_id not like 'cll_RACECHK%'
    and cs.interaction_id not like 'cll_DEV%'
    and cs.interaction_id not like 'cll_CHAIN%'
),
latest_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    coalesce(sa.applied_at_utc, sa.attributed_at, now()) as attributed_at_utc,
    sa.decision,
    coalesce(sa.needs_review, false) as needs_review
  from public.span_attributions sa
  order by sa.span_id, coalesce(sa.applied_at_utc, sa.attributed_at, now()) desc, sa.id desc
),
latest_pending_review as (
  select distinct on (rq.span_id)
    rq.span_id,
    rq.created_at as review_created_at_utc,
    rq.module
  from public.review_queue rq
  where rq.status = 'pending'
  order by rq.span_id, rq.created_at desc, rq.id desc
),
reviewed_by_proxy as (
  select distinct avf.span_id
  from public.attribution_validation_feedback avf
  where avf.source = 'llm_proxy_review'
),
pending_spans as (
  select
    s.span_id,
    s.interaction_id,
    la.decision,
    la.needs_review,
    (rq.span_id is not null) as has_pending_review,
    coalesce(rq.module, '') as pending_module,
    coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()) as pending_since_utc,
    extract(epoch from (now() - coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()))) / 3600.0 as age_hours
  from active_spans s
  left join latest_attr la on la.span_id = s.span_id
  left join latest_pending_review rq on rq.span_id = s.span_id
  left join reviewed_by_proxy rbp on rbp.span_id = s.span_id
  where (
    la.span_id is null
    or la.decision is null
    or la.decision = 'review'
    or la.needs_review = true
  )
    and rbp.span_id is null
),
bucketed as (
  select
    case
      when has_pending_review and age_hours >= 24 then 'review_queue_pending_over_24h'
      when has_pending_review then 'review_queue_pending_under_24h'
      when decision is null and not has_pending_review then 'missing_decision_no_review_queue'
      when decision = 'review' and not has_pending_review then 'review_decision_no_review_queue'
      when needs_review and not has_pending_review then 'needs_review_no_review_queue'
      when decision is null and pending_module = '' then 'unknown_pending_no_module'
      else 'other_uncovered'
    end as root_cause_bucket,
    span_id,
    interaction_id,
    age_hours,
    pending_since_utc
  from pending_spans
)
select
  root_cause_bucket,
  count(*)::int as span_count,
  round(max(age_hours)::numeric, 2) as max_age_hours,
  min(pending_since_utc) as oldest_pending_since_utc
from bucketed
group by root_cause_bucket
order by span_count desc, root_cause_bucket;

with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    coalesce(cs.created_at, now()) as span_created_at_utc
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
    and cs.interaction_id not like 'cll_SHADOW%'
    and cs.interaction_id not like 'cll_RACECHK%'
    and cs.interaction_id not like 'cll_DEV%'
    and cs.interaction_id not like 'cll_CHAIN%'
),
latest_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    coalesce(sa.applied_at_utc, sa.attributed_at, now()) as attributed_at_utc,
    sa.decision,
    coalesce(sa.needs_review, false) as needs_review
  from public.span_attributions sa
  order by sa.span_id, coalesce(sa.applied_at_utc, sa.attributed_at, now()) desc, sa.id desc
),
latest_pending_review as (
  select distinct on (rq.span_id)
    rq.span_id,
    rq.created_at as review_created_at_utc
  from public.review_queue rq
  where rq.status = 'pending'
  order by rq.span_id, rq.created_at desc, rq.id desc
),
reviewed_by_proxy as (
  select distinct avf.span_id
  from public.attribution_validation_feedback avf
  where avf.source = 'llm_proxy_review'
),
pending_spans as (
  select
    s.span_id,
    s.interaction_id,
    coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()) as pending_since_utc,
    extract(epoch from (now() - coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()))) / 3600.0 as age_hours
  from active_spans s
  left join latest_attr la on la.span_id = s.span_id
  left join latest_pending_review rq on rq.span_id = s.span_id
  left join reviewed_by_proxy rbp on rbp.span_id = s.span_id
  where (
    la.span_id is null
    or la.decision is null
    or la.decision = 'review'
    or la.needs_review = true
  )
    and rbp.span_id is null
)
select
  interaction_id,
  count(*)::int as pending_spans,
  round(max(age_hours)::numeric, 2) as max_age_hours,
  min(pending_since_utc) as oldest_pending_since_utc,
  (array_agg(span_id order by age_hours desc, span_id))[1:5] as sample_span_ids
from pending_spans
where age_hours >= 24
group by interaction_id
order by pending_spans desc, max_age_hours desc, interaction_id
limit 15;

with last_jc as (
  select max(created_at) as ts
  from public.journal_claims
),
inter_since as (
  select
    i.project_id,
    p.name as project_name,
    i.interaction_id,
    i.event_at_utc
  from public.interactions i
  join public.projects p on p.id = i.project_id
  cross join last_jc
  where i.event_at_utc > last_jc.ts
),
claim_calls as (
  select distinct call_id
  from public.journal_claims
)
select
  project_id,
  project_name,
  count(*)::int as interactions_since_last_claim,
  count(*) filter (where cc.call_id is null)::int as interactions_without_claims_since_last_claim,
  min(event_at_utc) as first_interaction_since,
  max(event_at_utc) as latest_interaction_since
from inter_since s
left join claim_calls cc on cc.call_id = s.interaction_id
group by project_id, project_name
order by interactions_without_claims_since_last_claim desc, latest_interaction_since desc
limit 20;
