
-- Contact scoring dedup table
-- Tracks which (contact_id, interaction_id) pairs have been scored
-- Prevents duplicate stat increments on pipeline replay
CREATE TABLE IF NOT EXISTS public.contact_scoring_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id uuid NOT NULL REFERENCES contacts(id),
  interaction_id text NOT NULL,
  transcript_chars integer NOT NULL DEFAULT 0,
  scored_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(contact_id, interaction_id)
);

-- Index for fast lookup during trigger
CREATE INDEX IF NOT EXISTS idx_csl_contact_interaction 
  ON public.contact_scoring_log(contact_id, interaction_id);

-- Audit table for suppressed duplicate scores
CREATE TABLE IF NOT EXISTS public.contact_scoring_suppressions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id uuid NOT NULL REFERENCES contacts(id),
  interaction_id text NOT NULL,
  suppressed_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL DEFAULT 'duplicate_interaction'
);

-- Enable RLS
ALTER TABLE public.contact_scoring_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contact_scoring_suppressions ENABLE ROW LEVEL SECURITY;

-- Service-role only policies (pipeline writes via service role)
CREATE POLICY "Service role full access" ON public.contact_scoring_log
  FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "Service role full access" ON public.contact_scoring_suppressions
  FOR ALL USING (auth.role() = 'service_role');

COMMENT ON TABLE public.contact_scoring_log IS 'Dedup log for contact interaction scoring. Prevents double-counting on pipeline replay.';
COMMENT ON TABLE public.contact_scoring_suppressions IS 'Audit trail for suppressed duplicate contact scores.';
;
