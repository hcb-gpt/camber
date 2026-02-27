-- Add shadow replay flags for production/shadow row disambiguation.
ALTER TABLE public.interactions
ADD COLUMN IF NOT EXISTS is_shadow boolean NOT NULL DEFAULT false;
ALTER TABLE public.calls_raw
ADD COLUMN IF NOT EXISTS is_shadow boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS idx_interactions_is_shadow ON public.interactions (is_shadow);
CREATE INDEX IF NOT EXISTS idx_calls_raw_is_shadow ON public.calls_raw (is_shadow);
