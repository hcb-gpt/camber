-- Proof for queue_ext__assistant_context_views_per_project_review_queue_summary__20260228

select
  project_id,
  project_name,
  pending_reviews_total,
  pending_reviews_7d,
  oldest_pending_created_at,
  latest_pending_created_at
from public.v_review_queue_project_summary
order by pending_reviews_total desc
limit 20;

explain (costs, verbose, format text)
select
  project_id,
  project_name,
  pending_reviews_total,
  pending_reviews_7d
from public.v_review_queue_project_summary
order by pending_reviews_total desc
limit 20;
