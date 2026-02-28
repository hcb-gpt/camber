-- Pipeline-health snapshot for DATA lane incidents:
-- - hard_drop SLA breach
-- - redline refresh / journal stale alerts

select
  generated_at_utc,
  sla_window_hours,
  hard_drop_deadline_hours,
  pending_total,
  pending_by_age_bucket,
  sla_breach_count
from public.v_hard_drop_sla_monitor;

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
    to_jsonb(sa) as attr_json
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
    extract(epoch from (now() - coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()))) / 3600.0 as age_hours,
    (rq.span_id is not null) as has_pending_review
  from active_spans s
  left join latest_attr la on la.span_id = s.span_id
  left join latest_pending_review rq on rq.span_id = s.span_id
  left join reviewed_by_proxy rbp on rbp.span_id = s.span_id
  where (
    la.span_id is null
    or nullif(la.attr_json->>'decision', '') is null
    or la.attr_json->>'decision' = 'review'
    or coalesce((la.attr_json->>'needs_review')::boolean, false) = true
  )
    and rbp.span_id is null
)
select
  count(*)::int as pending_total,
  count(*) filter (where age_hours >= 24)::int as sla_breach_count,
  count(*) filter (where age_hours >= 48)::int as age_48h_plus,
  count(*) filter (where has_pending_review)::int as pending_with_review_queue,
  count(*) filter (where not has_pending_review)::int as pending_without_review_queue
from pending_spans;

select
  total_spans_5min,
  breached_count,
  breach_rate_pct,
  worst_breach_minutes
from public.v_span_sla_summary;

select
  last_call_event,
  last_call_ingested,
  call_stale_minutes,
  last_sms_event,
  last_sms_ingested,
  sms_stale_minutes,
  last_interaction,
  interaction_stale_minutes,
  pending_review_count,
  last_diagnostic_error,
  pipeline_ok
from public.pipeline_heartbeat;

select
  capability,
  total,
  last_at,
  hours_stale
from public.v_pipeline_health
order by hours_stale desc nulls last;

select
  monitor_name,
  fired_at,
  acked,
  metric_snapshot->>'status' as status,
  metric_snapshot->>'sla_breach_count' as sla_breach_count,
  metric_snapshot->>'pending_total' as pending_total,
  metric_snapshot->>'journal_stale' as journal_stale,
  metric_snapshot->>'mat_project_stale' as mat_project_stale,
  metric_snapshot->>'mat_contact_stale' as mat_contact_stale,
  metric_snapshot->>'mat_belief_stale' as mat_belief_stale
from public.monitor_alerts
where monitor_name in ('hard_drop_sla_monitor_v1', 'redline_refresh_monitor_v1')
  and fired_at >= now() - interval '12 hours'
order by fired_at desc
limit 30;

with last_jc as (
  select max(created_at) as ts
  from public.journal_claims
),
inter as (
  select i.interaction_id, i.event_at_utc
  from public.interactions i, last_jc
  where i.event_at_utc > last_jc.ts
),
jc_calls as (
  select distinct call_id
  from public.journal_claims
)
select
  (select ts from last_jc) as last_journal_claim_at,
  count(*)::int as interactions_since_last_claim,
  count(*) filter (where jc.call_id is null)::int as interactions_without_claims,
  min(inter.event_at_utc) as first_interaction_since,
  max(inter.event_at_utc) as latest_interaction_since
from inter
left join jc_calls jc
  on jc.call_id = inter.interaction_id;

