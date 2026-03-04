-- Propose: unique constraint for active tram_presence (prevents split-brain duplicates)
-- Propose: decide on `model` column. Add it so the server doesn't fail trying to insert it.

-- 1. Add model column to match what the server expects (from prior FMs)
ALTER TABLE public.tram_presence ADD COLUMN IF NOT EXISTS model text;

-- 2. Add unique constraint to prevent split-brain duplicates for the same active session
-- We only enforce uniqueness on active sessions (where retired_at is null).
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_tram_presence 
ON public.tram_presence (origin_session, role) 
WHERE retired_at IS NULL;
