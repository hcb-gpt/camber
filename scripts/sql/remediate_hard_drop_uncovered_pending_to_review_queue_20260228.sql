-- Remediation: seed pending review_queue rows for uncovered hard-drop spans.
-- Idempotent for this run via batch_run_id + pending-row existence guard.

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
uncovered as (
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
    and rq.span_id is null
),
upd as (
  update public.review_queue rq
  set
    interaction_id = u.interaction_id,
    reasons = array['hard_drop_pending_uncovered']::text[],
    reason_codes = array['hard_drop_pending_uncovered']::text[],
    context_payload = coalesce(rq.context_payload, '{}'::jsonb) || jsonb_build_object(
      'source', 'data1_hard_drop_remediation_20260228',
      'pending_since_utc', u.pending_since_utc,
      'age_hours', round(u.age_hours::numeric, 3)
    ),
    status = 'pending',
    module = 'attribution',
    requires_reprocess = true,
    resolved_at = null,
    resolved_by = null,
    resolution_action = null,
    resolution_notes = null,
    updated_at = now(),
    batch_run_id = 'data1_hard_drop_requeue_20260228',
    dedupe_key = 'hard_drop_uncovered:' || u.span_id::text
  from uncovered u
  where rq.span_id = u.span_id
  returning
    rq.id,
    rq.interaction_id,
    rq.span_id,
    rq.updated_at as created_at,
    rq.batch_run_id
),
to_insert as (
  select u.*
  from uncovered u
  where not exists (
    select 1
    from public.review_queue rq
    where rq.span_id = u.span_id
  )
),
ins as (
  insert into public.review_queue (
    interaction_id,
    span_id,
    reasons,
    reason_codes,
    context_payload,
    status,
    module,
    requires_reprocess,
    batch_run_id,
    dedupe_key
  )
  select
    u.interaction_id,
    u.span_id,
    array['hard_drop_pending_uncovered']::text[],
    array['hard_drop_pending_uncovered']::text[],
    jsonb_build_object(
      'source', 'data1_hard_drop_remediation_20260228',
      'pending_since_utc', u.pending_since_utc,
      'age_hours', round(u.age_hours::numeric, 3)
    ),
    'pending',
    'attribution',
    true,
    'data1_hard_drop_requeue_20260228',
    'hard_drop_uncovered:' || u.span_id::text
  from to_insert u
  returning
    id,
    interaction_id,
    span_id,
    created_at,
    batch_run_id
)
select *
from (
  select * from upd
  union all
  select * from ins
) z
order by created_at desc;
