create or replace function public.get_hard_drop_sla_monitor(
  p_sla_window_hours integer default 1,
  p_hard_drop_deadline_hours integer default 24,
  p_top_n_clusters integer default 10
)
returns table (
  generated_at_utc timestamptz,
  sla_window_hours integer,
  hard_drop_deadline_hours integer,
  pending_total integer,
  pending_by_age_bucket jsonb,
  top_interaction_clusters jsonb,
  sla_breach_count integer
)
language sql
stable
set search_path = public
as $$
with active_spans as (
  select
    cs.id as span_id,
    cs.interaction_id,
    coalesce(cs.created_at, now()) as span_created_at_utc
  from public.conversation_spans cs
  where coalesce(cs.is_superseded, false) = false
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
pending_spans as (
  select
    s.span_id,
    s.interaction_id,
    coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now()) as pending_since_utc,
    extract(
      epoch from (
        now() - coalesce(rq.review_created_at_utc, la.attributed_at_utc, s.span_created_at_utc, now())
      )
    ) / 3600.0 as age_hours
  from active_spans s
  left join latest_attr la
    on la.span_id = s.span_id
  left join latest_pending_review rq
    on rq.span_id = s.span_id
  where
    la.span_id is null
    or nullif(la.attr_json->>'decision', '') is null
    or la.attr_json->>'decision' = 'review'
    or coalesce((la.attr_json->>'needs_review')::boolean, false) = true
),
clustered as (
  select
    p.interaction_id,
    count(*)::int as pending_spans,
    round(max(p.age_hours)::numeric, 2) as max_age_hours,
    min(p.pending_since_utc) as oldest_pending_since_utc,
    to_jsonb((array_agg(p.span_id order by p.age_hours desc, p.span_id))[1:5]) as sample_span_ids
  from pending_spans p
  where p.age_hours >= greatest(coalesce(p_sla_window_hours, 1), 0)
  group by p.interaction_id
  order by pending_spans desc, max_age_hours desc, p.interaction_id
  limit greatest(coalesce(p_top_n_clusters, 10), 1)
)
select
  now() at time zone 'utc' as generated_at_utc,
  greatest(coalesce(p_sla_window_hours, 1), 0) as sla_window_hours,
  greatest(coalesce(p_hard_drop_deadline_hours, 24), 0) as hard_drop_deadline_hours,
  count(*) filter (
    where p.age_hours >= greatest(coalesce(p_sla_window_hours, 1), 0)
  )::int as pending_total,
  jsonb_build_object(
    '1h', count(*) filter (where p.age_hours >= 1 and p.age_hours < 6),
    '6h', count(*) filter (where p.age_hours >= 6 and p.age_hours < 24),
    '24h', count(*) filter (where p.age_hours >= 24 and p.age_hours < 48),
    '48h+', count(*) filter (where p.age_hours >= 48)
  ) as pending_by_age_bucket,
  coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'interaction_id', c.interaction_id,
          'pending_spans', c.pending_spans,
          'max_age_hours', c.max_age_hours,
          'oldest_pending_since_utc', c.oldest_pending_since_utc,
          'sample_span_ids', c.sample_span_ids
        )
        order by c.pending_spans desc, c.max_age_hours desc, c.interaction_id
      )
      from clustered c
    ),
    '[]'::jsonb
  ) as top_interaction_clusters,
  count(*) filter (
    where p.age_hours >= greatest(coalesce(p_hard_drop_deadline_hours, 24), 0)
  )::int as sla_breach_count
from pending_spans p;
$$;

comment on function public.get_hard_drop_sla_monitor(integer, integer, integer) is
  'Read-only hard-drop SLA monitor metrics. Defaults: SLA window=1h, hard-drop deadline=24h.';

grant execute on function public.get_hard_drop_sla_monitor(integer, integer, integer) to service_role;;
