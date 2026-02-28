-- Review queue rollups for operator dashboards.

create or replace view public.v_review_queue_reason_daily as
select
  date_trunc('day', rq.created_at)::date as day,
  coalesce(rq.module, 'unknown') as module,
  rc.reason_code,
  count(*)::int as pending_count,
  min(rq.created_at) as first_seen_at,
  max(rq.created_at) as last_seen_at
from public.review_queue rq
cross join lateral unnest(coalesce(rq.reason_codes, array['unknown']::text[])) as rc(reason_code)
where rq.status = 'pending'
group by 1,2,3;

create or replace view public.v_review_queue_top_interactions as
select
  rq.interaction_id,
  coalesce(rq.module, 'unknown') as module,
  count(*)::int as pending_count,
  array_agg(distinct rc.reason_code order by rc.reason_code) as reason_codes,
  min(rq.created_at) as first_seen_at,
  max(rq.created_at) as last_seen_at
from public.review_queue rq
cross join lateral unnest(coalesce(rq.reason_codes, array['unknown']::text[])) as rc(reason_code)
where rq.status = 'pending'
  and rq.interaction_id is not null
  and rq.interaction_id !~* '^cll_(dev|shadow|racechk)'
group by 1,2
order by pending_count desc, last_seen_at desc;

create or replace view public.v_review_queue_summary as
select
  count(*)::int as pending_total,
  count(*) filter (where coalesce(module,'') = '' or module='attribution')::int as pending_attribution,
  count(*) filter (where reason_codes @> array['coverage_gap']::text[])::int as pending_coverage_gap,
  count(*) filter (where reason_codes @> array['weak_anchor']::text[])::int as pending_weak_anchor,
  max(created_at) as latest_pending_created_at
from public.review_queue
where status='pending';

grant select on public.v_review_queue_reason_daily to authenticated, anon, service_role;
grant select on public.v_review_queue_top_interactions to authenticated, anon, service_role;
grant select on public.v_review_queue_summary to authenticated, anon, service_role;

comment on view public.v_review_queue_reason_daily is
'Pending review_queue rollup by day/module/reason_code. reason_codes array is unnested; includes unknown placeholder when missing.';

comment on view public.v_review_queue_top_interactions is
'Top interactions by pending review_queue count (pending only), excludes dev/shadow/racechk. Includes distinct reason_codes list.';

comment on view public.v_review_queue_summary is
'High-level pending review_queue summary: totals + coverage_gap/weak_anchor counts + latest pending timestamp.';
;
