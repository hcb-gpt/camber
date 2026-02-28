-- Add writer-origin tagging for review_queue lifecycle writes.
-- Defaults legacy and pipeline paths to 'pipeline'; redline clients can set 'redline'.

ALTER TABLE public.review_queue
  ADD COLUMN IF NOT EXISTS source text;

UPDATE public.review_queue
SET source = 'pipeline'
WHERE source IS NULL;

ALTER TABLE public.review_queue
  ALTER COLUMN source SET DEFAULT 'pipeline';

ALTER TABLE public.review_queue
  ALTER COLUMN source SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'review_queue_source_check'
      AND conrelid = 'public.review_queue'::regclass
  ) THEN
    ALTER TABLE public.review_queue
      ADD CONSTRAINT review_queue_source_check
      CHECK (source IN ('pipeline', 'redline'));
  END IF;
END $$;

COMMENT ON COLUMN public.review_queue.source IS
  'Writer origin for review_queue writes: pipeline (default) or redline (iOS/manual attribution paths).';
