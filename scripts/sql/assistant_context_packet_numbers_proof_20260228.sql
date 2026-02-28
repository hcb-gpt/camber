-- Proof pack for p0__assistant_context_packet_data_quality_defs_top_projects_reviews_claims_loops__20260228
-- Scope: Woodbery + Moss, comparing current view fields vs source-of-truth totals and 7-day windows.

with target_projects as (
  select p.id as project_id, p.name as project_name
  from public.projects p
  where lower(p.name) in ('woodbery residence', 'moss residence')
),
view_snapshot as (
  select
    tp.project_name,
    vpf.interactions_7d as view_interactions_7d,
    vpf.active_journal_claims as view_active_journal_claims,
    vpf.open_loops as view_open_loops,
    vpf.pending_reviews as view_pending_reviews
  from target_projects tp
  join public.v_project_feed vpf on vpf.project_id = tp.project_id
),
source_rollup as (
  select
    tp.project_name,
    max(i.event_at_utc) as last_interaction_at,
    count(*) filter (
      where i.event_at_utc >= now() - interval '7 days'
    )::bigint as interactions_7d,
    (
      select count(*)::bigint
      from public.journal_claims jc
      where jc.project_id = tp.project_id
        and jc.active = true
    ) as claims_active_total,
    (
      select count(*)::bigint
      from public.journal_claims jc
      where jc.project_id = tp.project_id
        and jc.active = true
        and jc.created_at >= now() - interval '7 days'
    ) as claims_active_7d,
    (
      select count(*)::bigint
      from public.journal_open_loops jol
      where jol.project_id = tp.project_id
        and jol.status = 'open'
    ) as open_loops_total,
    (
      select count(*)::bigint
      from public.journal_open_loops jol
      where jol.project_id = tp.project_id
        and jol.status = 'open'
        and jol.created_at >= now() - interval '7 days'
    ) as open_loops_7d,
    (
      select count(*)::bigint
      from public.span_attributions sa
      join public.conversation_spans cs on cs.id = sa.span_id
      where sa.needs_review = true
        and cs.interaction_id in (
          select i2.interaction_id
          from public.interactions i2
          where i2.project_id = tp.project_id
        )
    ) as span_needs_review_total,
    (
      select count(*)::bigint
      from public.review_queue rq
      join public.interactions i2 on i2.interaction_id = rq.interaction_id
      where rq.status = 'pending'
        and i2.project_id = tp.project_id
    ) as review_queue_pending_total,
    (
      select count(*)::bigint
      from public.review_queue rq
      join public.interactions i2 on i2.interaction_id = rq.interaction_id
      where rq.status = 'pending'
        and i2.project_id = tp.project_id
        and rq.created_at >= now() - interval '7 days'
    ) as review_queue_pending_7d
  from target_projects tp
  left join public.interactions i on i.project_id = tp.project_id
  group by tp.project_id, tp.project_name
)
select
  sr.project_name,
  sr.last_interaction_at,
  vs.view_interactions_7d,
  sr.interactions_7d as source_interactions_7d,
  vs.view_active_journal_claims,
  sr.claims_active_total,
  sr.claims_active_7d,
  vs.view_open_loops,
  sr.open_loops_total,
  sr.open_loops_7d,
  vs.view_pending_reviews,
  sr.span_needs_review_total,
  sr.review_queue_pending_total,
  sr.review_queue_pending_7d
from source_rollup sr
join view_snapshot vs using (project_name)
order by sr.project_name;

select
  category,
  project,
  detail,
  speaker,
  created_at,
  hours_ago
from public.v_who_needs_you_today
where lower(project) in ('woodbery', 'moss')
   or lower(project) in ('woodbery residence', 'moss residence')
order by category, created_at desc;

select
  pending_total,
  pending_attribution,
  pending_coverage_gap,
  pending_weak_anchor,
  latest_pending_created_at
from public.v_review_queue_summary;
