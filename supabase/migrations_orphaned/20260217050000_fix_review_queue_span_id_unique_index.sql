-- Fix ai-router review_queue upsert ON CONFLICT(span_id)
-- Postgres cannot infer partial unique indexes for ON CONFLICT (columns) without an explicit WHERE.
-- Make span_id uniqueness non-partial so `.upsert(..., { onConflict: "span_id" })` works reliably.

DROP INDEX IF EXISTS public.review_queue_span_id_uq;

CREATE UNIQUE INDEX IF NOT EXISTS review_queue_span_id_uq
  ON public.review_queue (span_id);

