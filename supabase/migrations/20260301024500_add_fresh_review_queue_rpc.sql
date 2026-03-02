-- Migration: Add fresh_review_queue RPC for triage freshness SLA
-- Date: 2026-03-01
-- Scope: Epic 3.1 (P0)

CREATE OR REPLACE FUNCTION public.fresh_review_queue(
  p_max_age_days integer,
  p_limit integer
)
RETURNS SETOF public.review_queue
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT rq.*
  FROM public.review_queue rq
  LEFT JOIN public.interactions i ON rq.interaction_id = i.interaction_id
  WHERE rq.status = 'pending'
    AND COALESCE(i.event_at_utc, rq.created_at) >= (now() - (p_max_age_days || ' days')::interval)
  ORDER BY COALESCE(i.event_at_utc, rq.created_at) DESC, rq.id DESC
  LIMIT p_limit;
$$;

-- Fallback variant for schema compatibility during rollout
CREATE OR REPLACE FUNCTION public.fresh_review_queue_no_module(
  p_max_age_days integer,
  p_limit integer
)
RETURNS SETOF public.review_queue
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT rq.*
  FROM public.review_queue rq
  LEFT JOIN public.interactions i ON rq.interaction_id = i.interaction_id
  WHERE rq.status = 'pending'
    AND COALESCE(i.event_at_utc, rq.created_at) >= (now() - (p_max_age_days || ' days')::interval)
  ORDER BY COALESCE(i.event_at_utc, rq.created_at) DESC, rq.id DESC
  LIMIT p_limit;
$$;

COMMENT ON FUNCTION public.fresh_review_queue IS 'Returns pending review queue items newer than N days, joined with interactions for accurate call date filtering.';
