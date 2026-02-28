-- Extend v_review_queue_summary with explicit 7d pending windows.

create or replace view public.v_review_queue_summary as
select
  count(*)::int as pending_total,
  count(*) filter (
    where coalesce(module, '') = '' or module = 'attribution'
  )::int as pending_attribution,
  count(*) filter (
    where reason_codes @> array['coverage_gap']::text[]
  )::int as pending_coverage_gap,
  count(*) filter (
    where reason_codes @> array['weak_anchor']::text[]
  )::int as pending_weak_anchor,
  max(created_at) as latest_pending_created_at,
  count(*) filter (
    where created_at >= now() - interval '7 days'
  )::int as pending_total_7d,
  count(*) filter (
    where (coalesce(module, '') = '' or module = 'attribution')
      and created_at >= now() - interval '7 days'
  )::int as pending_attribution_7d,
  count(*) filter (
    where reason_codes @> array['coverage_gap']::text[]
      and created_at >= now() - interval '7 days'
  )::int as pending_coverage_gap_7d,
  count(*) filter (
    where reason_codes @> array['weak_anchor']::text[]
      and created_at >= now() - interval '7 days'
  )::int as pending_weak_anchor_7d,
  now() as computed_at_utc
from public.review_queue
where status = 'pending';

comment on view public.v_review_queue_summary is
'High-level pending review_queue summary with explicit lifetime totals and 7d windowed totals.';
