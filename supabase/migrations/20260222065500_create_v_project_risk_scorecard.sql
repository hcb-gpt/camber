-- Create v_project_risk_scorecard
-- risk_score = (open_loops * 3) + (striking_signals * 2) + (low_confidence_reviews * 1)

create or replace view public.v_project_risk_scorecard as
with latest_span_attr as (
  select distinct on (sa.span_id)
    sa.span_id,
    coalesce(sa.applied_project_id, sa.project_id) as project_id
  from public.span_attributions sa
  order by sa.span_id, sa.attributed_at desc nulls last, sa.id desc
),
open_loops as (
  select
    jol.project_id,
    count(*) filter (where coalesce(jol.status, 'open') = 'open')::bigint as open_loop_count,
    max(jol.created_at) as last_open_loop_at
  from public.journal_open_loops jol
  where jol.project_id is not null
  group by jol.project_id
),
striking as (
  select
    coalesce(i.project_id, lsa.project_id) as project_id,
    count(*)::bigint as striking_signal_count,
    max(ss.created_at) as last_striking_at
  from public.striking_signals ss
  left join public.interactions i
    on i.interaction_id = ss.interaction_id
  left join latest_span_attr lsa
    on lsa.span_id = ss.span_id
  where coalesce(i.project_id, lsa.project_id) is not null
  group by coalesce(i.project_id, lsa.project_id)
),
reviews as (
  select
    coalesce(
      case
        when coalesce(vr.applied_project_id, '') ~* '^[0-9a-f-]{36}$'
          then vr.applied_project_id::uuid
        else null
      end,
      case
        when coalesce(vr.predicted_project_id, '') ~* '^[0-9a-f-]{36}$'
          then vr.predicted_project_id::uuid
        else null
      end,
      i.project_id
    ) as project_id,
    count(*) filter (
      where coalesce(vr.review_status, 'pending') = 'pending'
        and coalesce(vr.confidence, 0) < 0.8
    )::bigint as low_confidence_review_count,
    max(vr.review_created_at) as last_review_at
  from public.v_review_queue_spans vr
  left join public.interactions i
    on i.interaction_id = vr.interaction_id
  group by coalesce(
    case
      when coalesce(vr.applied_project_id, '') ~* '^[0-9a-f-]{36}$'
        then vr.applied_project_id::uuid
      else null
    end,
    case
      when coalesce(vr.predicted_project_id, '') ~* '^[0-9a-f-]{36}$'
        then vr.predicted_project_id::uuid
      else null
    end,
    i.project_id
  )
)
select
  p.id as project_id,
  p.name as project_name,
  coalesce(ol.open_loop_count, 0)::bigint as open_loop_count,
  coalesce(s.striking_signal_count, 0)::bigint as striking_signal_count,
  coalesce(r.low_confidence_review_count, 0)::bigint as low_confidence_review_count,
  (
    coalesce(ol.open_loop_count, 0) * 3
    + coalesce(s.striking_signal_count, 0) * 2
    + coalesce(r.low_confidence_review_count, 0)
  )::bigint as risk_score,
  greatest(
    coalesce(ol.last_open_loop_at, 'epoch'::timestamptz),
    coalesce(s.last_striking_at, 'epoch'::timestamptz),
    coalesce(r.last_review_at, 'epoch'::timestamptz)
  ) as last_activity_date
from public.projects p
left join open_loops ol
  on ol.project_id = p.id
left join striking s
  on s.project_id = p.id
left join reviews r
  on r.project_id = p.id;
comment on view public.v_project_risk_scorecard is
  'Project risk scorecard from open loops, striking signals, and low-confidence pending reviews.';
