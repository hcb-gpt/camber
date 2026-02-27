-- Enable Realtime subscriptions for review_queue and grant anon read access.
--
-- Problem: The iOS app subscribes to review_queue Postgres changes via
-- Supabase Realtime, but the table was never added to the publication
-- and had no anon SELECT policy. Result: subscription silently fails,
-- attribution status changes never push to the app.
--
-- Fix:
--   1. Add review_queue to supabase_realtime publication
--   2. Add anon_read_review_queue RLS policy (matches claim_grades,
--      interactions, sms_messages pattern)
--
-- Thread: ios_sync_fix
-- Author: data-r2

-- Idempotent: ALTER PUBLICATION ... ADD TABLE is a no-op if already present
-- (Postgres 15+ raises a NOTICE, not an error).
ALTER PUBLICATION supabase_realtime ADD TABLE review_queue;

-- RLS policy: anon can SELECT all review_queue rows.
-- Edge functions use service_role, so this only affects the iOS anon client.
CREATE POLICY anon_read_review_queue ON review_queue
  FOR SELECT
  TO anon
  USING (true);
