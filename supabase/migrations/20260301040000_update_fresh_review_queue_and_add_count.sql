-- Migration: Update fresh_review_queue and add count for triage freshness SLA
-- Date: 2026-03-01
-- Scope: Epic 3.1 (P0)
-- Improvements: Adds span_id and module filters to match Edge Function logic.

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
    AND rq.span_id IS NOT NULL
    AND (rq.module = 'attribution' OR rq.module IS NULL)
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
    AND rq.span_id IS NOT NULL
    AND COALESCE(i.event_at_utc, rq.created_at) >= (now() - (p_max_age_days || ' days')::interval)
  ORDER BY COALESCE(i.event_at_utc, rq.created_at) DESC, rq.id DESC
  LIMIT p_limit;
$$;

-- NEW: Count function for accurate badge/progress reporting
CREATE OR REPLACE FUNCTION public.fresh_review_queue_count(
  p_max_age_days integer
)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT count(*)
  FROM public.review_queue rq
  LEFT JOIN public.interactions i ON rq.interaction_id = i.interaction_id
  WHERE rq.status = 'pending'
    AND rq.span_id IS NOT NULL
    AND (rq.module = 'attribution' OR rq.module IS NULL)
    AND COALESCE(i.event_at_utc, rq.created_at) >= (now() - (p_max_age_days || ' days')::interval);
$$;

COMMENT ON FUNCTION public.fresh_review_queue IS 'Returns pending review queue items newer than N days, joined with interactions for accurate call date filtering.';
COMMENT ON FUNCTION public.fresh_review_queue_count IS 'Returns count of pending review queue items newer than N days.';
