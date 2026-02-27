create or replace view public.v_span_sla_breach as
select
  cs.id as span_id,
  cs.interaction_id,
  cs.span_index,
  cs.created_at as span_created_at,
  round(extract(epoch from (now() - cs.created_at)) / 60.0, 2) as age_minutes,
  sa.decision,
  sa.project_id as predicted_project_id,
  sa.applied_project_id,
  p.name as applied_project_name,
  cs.word_count,
  cs.time_start_sec,
  cs.time_end_sec,
  cs.char_start,
  cs.char_end,
  cs.transcript_segment
from public.conversation_spans cs
left join public.span_attributions sa on sa.span_id = cs.id
left join public.review_queue rq on rq.span_id = cs.id
left join public.projects p on p.id = sa.applied_project_id
where cs.is_superseded = false
  and cs.created_at > now() - interval '24 hours'
  and extract(epoch from (now() - cs.created_at)) / 60.0 > 5
  and (sa.span_id is null or sa.decision is null)
  and coalesce(sa.needs_review, false) = false
  and rq.span_id is null;

create or replace view public.v_span_sla_summary as
with base as (
  select
    count(*)::int as total_spans_5min
  from public.conversation_spans cs
  where cs.is_superseded = false
    and cs.created_at > now() - interval '24 hours'
    and extract(epoch from (now() - cs.created_at)) / 60.0 > 5
),
breach as (
  select
    count(*)::int as breached_count,
    max(age_minutes) as worst_breach_minutes
  from public.v_span_sla_breach
)
select
  base.total_spans_5min,
  breach.breached_count,
  case
    when base.total_spans_5min = 0 then 0
    else round((breach.breached_count::numeric / base.total_spans_5min::numeric) * 100, 2)
  end as breach_rate_pct,
  breach.worst_breach_minutes
from base cross join breach;

grant select on public.v_span_sla_breach to authenticated, anon, service_role;
grant select on public.v_span_sla_summary to authenticated, anon, service_role;

comment on view public.v_span_sla_breach is
'Per-span SLA breach list: non-superseded spans older than 5 minutes (last 24h) with no attribution decision and no needs_review/review_queue coverage.';

comment on view public.v_span_sla_summary is
'SLA summary over last 24h: total spans older than 5 min, breached count, breach rate %, and worst breach minutes, derived from v_span_sla_breach.';
;
