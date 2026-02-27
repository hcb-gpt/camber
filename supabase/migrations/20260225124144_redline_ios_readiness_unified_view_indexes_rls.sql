-- Redline iOS Readiness: 4A + 4B + 4C in one migration

-- ═══ STEP 4A: Unified redline_thread view ═══
CREATE OR REPLACE VIEW public.redline_thread AS
SELECT * FROM public.redline_contact_thread
UNION ALL
SELECT * FROM public.redline_sms_thread
ORDER BY event_at_utc DESC;

COMMENT ON VIEW public.redline_thread IS 'Unified Redline timeline: calls + SMS interleaved by date. iOS app queries this single view. Filter by contact_id.';

-- ═══ STEP 4B: Performance indexes (only missing ones) ═══
-- interactions: composite index for contact_id + event_at_utc sort
CREATE INDEX IF NOT EXISTS idx_interactions_contact_event
  ON public.interactions (contact_id, event_at_utc DESC);

-- sms_messages: contact_phone for SMS bridge view join
CREATE INDEX IF NOT EXISTS idx_sms_contact_phone
  ON public.sms_messages (contact_phone);

-- journal_claims(call_id) already exists: idx_journal_claims_call
-- claim_grades(claim_id, graded_by) already exists: claim_grades_claim_id_graded_by_key

-- ═══ STEP 4C: RLS + GRANT for anon key (iOS MVP) ═══

-- claim_grades: RLS already enabled from Step 1. Add anon policies.
CREATE POLICY "anon_read_grades" ON public.claim_grades
  FOR SELECT TO anon USING (true);

CREATE POLICY "anon_insert_grades" ON public.claim_grades
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "anon_update_grades" ON public.claim_grades
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- Grant anon SELECT on views
GRANT SELECT ON public.redline_thread TO anon;
GRANT SELECT ON public.redline_contact_thread TO anon;
GRANT SELECT ON public.redline_sms_thread TO anon;

-- Grant anon INSERT/UPDATE on claim_grades
GRANT SELECT, INSERT, UPDATE ON public.claim_grades TO anon;;
