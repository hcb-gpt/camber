-- Ensure interactions.is_nonsegmentable is migration-covered and idempotent.
-- Safe when column/index already exist in production.

ALTER TABLE public.interactions
  ADD COLUMN IF NOT EXISTS is_nonsegmentable boolean;

UPDATE public.interactions
SET is_nonsegmentable = false
WHERE is_nonsegmentable IS NULL;

UPDATE public.interactions
SET is_nonsegmentable = true
WHERE transcript_chars = 0 OR transcript_chars IS NULL;

ALTER TABLE public.interactions
  ALTER COLUMN is_nonsegmentable SET DEFAULT false;

ALTER TABLE public.interactions
  ALTER COLUMN is_nonsegmentable SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_interactions_is_nonsegmentable
  ON public.interactions (is_nonsegmentable);
